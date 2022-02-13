
#Thanks to henryk (@FHEM-Forum) for the original version of this module 
#and a few more who have added bits and pieces here and there.

package main;


sub
co2mini_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "co2mini::Define";
  $hash->{ReadyFn}  = "co2mini::Ready";
  $hash->{ReadFn}   = "co2mini::Read";
  $hash->{UndefFn}  = "co2mini::Undefine";
  $hash->{AttrFn}   = "co2mini::Attr";
  $hash->{AttrList} = "disable:0,1 updateTimeout device serverControl:fhem,external serverIp serverPort serverStartDelay ".
                      $readingFnAttributes;
}

#####################################

package co2mini;

use strict;
use warnings;

use POSIX;
use Fcntl;
use Errno;


sub Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my $name = $a[0];
	my $dev;
	my $addr;
	my $control = 'fhem';
  
	if(@a < 3) {
		#Nothing given, assume defaults
		$dev = '/dev/co2mini0';
		$addr = '127.0.0.1:41042';
	}elsif($a[2] =~ /^\//){
		#Device given, assume we control the server
		$dev = $a[2];
		$addr = '127.0.0.1:41042';
	}else{
		#Server address given, assume server is controlled externally
		$addr = $a[2];	
		$control = 'external';	
	};	
	my ($ip,$port) = split(/:/,$addr);
	$main::attr{$name}{serverControl} = $control;
	$main::attr{$name}{serverIp} = $ip;
	$main::attr{$name}{serverPort} = $port;
	$main::attr{$name}{device} = $dev;
  
	$hash->{NAME} = $name;
	$hash->{DeviceName} = $addr;  #Needed for DevIo
  
	Disconnect($hash);
	$main::readyfnlist{"$name.$addr"} = $hash;
  
	return undef;
}


sub OnConnect($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  main::Log3 $name, 3, "$name: OnConnect";
  main::readingsSingleUpdate($hash,"state",'opened', 1);
  $hash->{LAST_RECV} = time();
  queueConnectionCheck($hash);
}

sub Ready($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if main::AttrVal($name, "disable", 0 ) == 1;

    main::Log3 $name, 4, "$name: Ready"; 

	#Start server
    $hash->{helper}{buf} = "";
	if(main::AttrVal($name, "serverControl", "fhem") eq "fhem") {
		serverStart($hash);
		return undef unless $hash->{ServerStartTime};
		my $timeToConnect = main::AttrVal($name, "serverStartDelay", 3 ) - time() + $hash->{ServerStartTime};
		if($timeToConnect < 0) {
			$hash->{nextOpenDelay} = 10;
			return main::DevIo_OpenDev($hash, 1, "co2mini::OnConnect");
		}else{
			main::Log3 $name, 4, "$name: Waiting ".$timeToConnect." seconds to connect"; 
			return undef;
		};	
	}else{	
        return main::DevIo_OpenDev($hash, 1, "co2mini::OnConnect");
	};	
}

sub Disconnect($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  
  #Avoid starting again immediately
  delete $main::readyfnlist{$name.'.'.$hash->{DeviceName}};
    
  if (main::ReadingsVal($name, "state", "") eq "opened") {
      main::DevIo_CloseDev($hash);
  }
  
  #If we control the server, then shut this down as well
	if(main::AttrVal($name, "serverControl", "fhem") eq "fhem") {
		serverStop($hash);
	};  

  main::readingsSingleUpdate($hash,"state",'disconnected', 1);
}



sub updateData($$@)
{
  my ($hash, $showraw, @data) = @_;
  my $name = $hash->{NAME};

  main::Log3 $name, 5, "$name: data received " . join(" ", @data);
  if($#data < 4) {
    main::Log3 $name, 3, "$name: incoming data too short";
    return;
  }
  elsif($data[4] != 0xd) {
    main::Log3 $name, 3, "$name: unexpected byte 5";
    return;
  }
  elsif((($data[0] + $data[1] + $data[2]) & 0xff) != $data[3]) {
    main::Log3 $name, 3, "$name: checksum error ".sprintf("%X%X%X%X",$data[0],$data[1],$data[2],$data[3]);
    return;
  }

  my ($item, $val_hi, $val_lo, $rest) = @data;
  my $value = $val_hi << 8 | $val_lo;
    
  if($item == 0x50) {
    main::readingsBulkUpdate($hash, "co2", $value);
    $hash->{LAST_RECV} = time();
  } elsif($item == 0x42) {
    main::readingsBulkUpdate($hash, "temperature", $value/16.0 - 273.15);
	$hash->{LAST_RECV} = time();
  } elsif($item == 0x41 or $item == 0x44) {
	#It is not really clear whether the code for humidity is 0x41 or 0x44
	#the original version of this module had 0x44, but it seems that there
	#is at least one device out there sending the humidity with 0x41
    main::readingsBulkUpdate($hash, "humidity", $value/100.0);
	$hash->{LAST_RECV} = time();
  }
  if($showraw) {
    main::readingsBulkUpdate($hash, sprintf("raw_%02X", $item), $value);
  }
}

sub Read($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my ($buf, $readlength);

  my $showraw = main::AttrVal($name, "showraw", 0);

  main::readingsBeginUpdate($hash);
    
  $buf = main::DevIo_SimpleRead($hash);

  $readlength = length $buf;
  if(defined($buf) || ($readlength > 0)) {
    $hash->{LAST_RECV} = time();
    $hash->{helper}{buf} .= $buf;
    while ($hash->{helper}{buf} =~ /^(.{4,}\x0d)/s) {
      my @data = map { ord } split //, $1;
      substr($hash->{helper}{buf}, 0, $#data+1) = '';
      updateData($hash, $showraw, @data);
    }
  } else {
    main::Log3 $name, 1, "$name: network error or disconnected: $!";
  }

  if(!defined($readlength)) {
    if($!{EAGAIN} or $!{EWOULDBLOCK}) {
      # This is expected, ignore it
    } else {
		#This only seems to happen if the connection is broken. Let's try
		#to restart	
        main::Log3 $name, 1, "$name: device error or disconnected: $!";
		Disconnect($hash);
		#main::DevIo_Disconnected($hash);
		my $dev = $hash->{DeviceName};
		$main::readyfnlist{"$name.$dev"} = $hash;
		#delete $main::selectlist{"$name.$dev"};
		#Setting state "disconnected" does not create an event in DevIo
		main::readingsSingleUpdate($hash,"state",'disconnected', 1);
    }
  }

  main::readingsEndUpdate($hash, 1);
}


sub Undefine($$) {
  my ($hash, $arg) = @_;
  main::RemoveInternalTimer($hash);
  Disconnect($hash);
  return undef;
}

sub Attr($$$) {
  my ($cmd, $name, $attrName, $attrVal) = @_;

    my $hash = $main::defs{$name};

  if( $attrName eq "disable" ) {

    if( $cmd eq "set" && $attrVal ne "0" ) {
      Disconnect($hash);
    } else {
      my $dev = $hash->{DeviceName};
      $main::readyfnlist{"$name.$dev"} = $hash;
    }
  }
  
	return undef unless $attrName =~ /^(device|serverControl|serverIp|serverPort)$/;
	
	#Seems that we need to restart the server and the connection	
	my $serverIp = $main::attr{$name}{serverIp};
	$serverIp = '127.0.0.1' unless $serverIp;
	my $serverPort = $main::attr{$name}{serverPort};
	$serverPort = '41042' unless $serverPort;
	if($attrName eq 'serverIp') {
		if($cmd eq "set") {
			$serverIp = $attrVal;
		}else{
			$serverIp = '127.0.0.1';
		};
	}elsif($attrName eq 'serverPort') {
		if($cmd eq "set") {
			$serverPort = $attrVal;
		}else{
			$serverPort = '41042';
		};
	};	
		
	Disconnect($hash);	
	$hash->{DeviceName} = $serverIp.':'.$serverPort;		
	$main::readyfnlist{$name.'.'.$hash->{DeviceName}} = $hash;
	
	return undef;
}


sub queueConnectionCheck($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  
  return if(main::ReadingsVal($name, "state", "") ne "opened");
  
  my $time = main::AttrVal($name,'updateTimeout',120);
   
  main::RemoveInternalTimer($hash);
  main::InternalTimer(time() + $time, "co2mini::CheckConnection", $hash, 0);
}


sub CheckConnection($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  main::Log3 $name, 4, "$name: CheckConnection";
 
  return undef unless main::ReadingsVal($name, "state", "") eq "opened";

  my $lastRecvDiff = (time() - $hash->{LAST_RECV});
  my $updateInt = main::AttrVal($name,'updateTimeout',120);
  
  # give it 20% tolerance. 
  if ($lastRecvDiff > ($updateInt * 1.2)) {
    main::Log3 $name, 3, "$name: Connection lost! Last data from sensor received $lastRecvDiff s ago";
    main::DevIo_Disconnected($hash);
	#Setting state "disconnected" does not create an event in DevIo
	main::readingsSingleUpdate($hash,"state",'disconnected', 1);
    return undef;
  }
  main::Log3 $name, 4, "$name: Connection still alive. Last data from co2mini received $lastRecvDiff s ago";
  
  queueConnectionCheck($hash);
}


sub updateServerCommandLine($) {
	my ($hash) = @_;
	
	my $name = $hash->{NAME};
	my $device = main::AttrVal($name, "device", "/dev/co2mini0" );
	my $port = main::AttrVal($name, "serverPort", "41042" );
	my $baseDir = main::AttrVal('global', "modpath", "/opt/fhem" );
	my $commandLine = 'perl '.$baseDir.'/FHEM/lib/co2mini/co2mini_server.pl '
		.'-device='.$device.' -port='.$port;
	$hash->{commandLine} = $commandLine;
}


sub serverGetPid($$) {
	my ($hash, $commandLine) = @_;
	my $retVal = 0;
	
	my $ps = 'ps axwwo pid,args | grep "' . $commandLine . '" | grep -v grep';
	my @result = `$ps`;
	foreach my $psResult (@result) {
        $psResult =~ /(^[\t ]*[0-9]*)\s/;
		if ($psResult) {
			$psResult =~ /(^.*)\s.*perl.*/;
			$retVal = $1;
			last;
		}
	}
	
	return $retVal;
}


sub serverStart($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	delete $hash->{ServerPID};
	
	updateServerCommandLine($hash);
	my $pid = serverGetPid($hash, $hash->{commandLine});
	# Is a process with this command line already running? If yes then use this.
	if($pid && kill(0, $pid)) {
		main::Log3($hash, 4, "$name: Server already running with PID " . $pid. '. We are using this process.');
		$hash->{ServerPID} = $pid;
		$hash->{ServerStartTime} = time() unless $hash->{ServerStartTime};	
		return 'Server already running. (Re)Connected to PID '.$pid;
	};		
	#...otherwise try to start server
	system($hash->{commandLine} . '&');
	main::Log3($hash, 3, "$name: Start server with command line: " . $hash->{commandLine});
	$pid = serverGetPid($hash, $hash->{commandLine});
	if(!$pid) {
		delete $hash->{ServerStartTime};
		return 'Server could not be started';
	}
	$hash->{ServerPID} = $pid;
	$hash->{ServerStartTime} = time();
	main::Log3($hash, 3, "$name: Server was started with PID: " . $pid);
	$hash->{ServerSTATE} = 'started';
	return 'Server started with PID '.$pid;
}


sub serverStop($) {
	my ($hash) = @_;	
	my $name = $hash->{NAME};
	
	return undef unless $hash->{ServerPID};
	
	my $pid = $hash->{ServerPID};

	# Is there a process with the pid?
	if(!kill(0, $pid)) {
		main::Log3($name, 1, "$name: There is no server process with PID " . $pid . '.');	
		return undef;
	};	
	if(!kill('TERM', $pid)) {
		main::Log3($name, 1, "$name: Can't terminate server with PID " . $pid . '.');
		return undef;
	};	
	$hash->{ServerSTATE} = 'stopped';
	delete $hash->{ServerPID};
	delete $hash->{ServerStartTime};

	main::Log3($name, 3, "$name: Server with PID " . $pid . ' was terminated.');
	return undef;
};

1;

=pod
=begin html

<a name="co2mini"></a>
<h3>co2mini</h3>
<ul>
  Module for measuring temperature and air CO2 concentration with a co2mini like device. 
  These are available under a variety of different branding, but all register as a USB HID device
  with a vendor and product ID of 04d9:a052.
  For photos and further documentation on the reverse engineering process see
  <a href="https://hackaday.io/project/5301-reverse-engineering-a-low-cost-usb-co-monitor">Reverse-Engineering a low-cost USB CO2 monitor</a>.<br><br>

  Alternatively you can use a remote sensor with the <tt>co2mini_server.pl</tt> available in the FHEM base directory (usually /opt/fhem) under FHEM/lib/co2mini. Check <tt>perl co2mini_server.pl -help</tt> for possible arguments. It will listen to a given port and accept connections from clients.
  When configuring the FHEM module to connect to a remote <tt>co2mini_server.pl</tt>, simply supply <tt>address:port</tt> instead of the device node.<br>

  Notes:
  <ul>
    <li>FHEM, or the user running <tt>co2mini_server.pl</tt>, has to have permissions to open the device. To configure this with udev, you can copy the file in <tt>FHEM/lib/co2mini/90-co2mini.rules</tt> to <tt>/etc/udev/rules.d</tt>
	</li>
  </ul><br>

  <a name="co2mini-define"><b>Define</b></a>
  <ul>
    <code>define &lt;name&gt; co2mini [devicenode or address:port]</code><br>
    <br>

    Defines a co2mini device. Optionally a device node may be specified, otherwise this defaults to <tt>/dev/co2mini0</tt>.<br>
    Instead of a device node, a remote server can be specified by using <tt>address:port</tt>.<br><br>

    Examples:
    <ul>
	<li>
      <code>define co2 co2mini</code><br>
	  This means that the device is directly connected to the same server and the device name is /dev/co2mini0. The co2mini module will then automatically start the co2mini server. 
	</li>
	<li>
      <code>define co2 co2mini /dev/co2mini5</code><br>
	  This means that the device is directly connected to the same server and the device name is /dev/co2mini5. The co2mini module will then automatically start the co2mini server.
	</li>
	<li>
      <code>define co2 co2mini raspberry:23231</code><br>
	  This connects to a server with the name "raspberry" where the co2mini server listens to port 23231. I.e. the server has to be started with <tt>perl co2mini_server.pl -port=23231</tt> manually or by some other script on the server named "raspberry".
	</li>  
  </ul>
  <br>
  The arguments can be overriden using the attributes <tt>device</tt>, <tt>serverControl</tt>, <tt>serverIp</tt> and <tt>serverPort</tt>.
  <br><br>
  </ul>

  <a id="co2mini-readings"><b>Readings</b></a>
  <dl>
  <dt>co2</dt><dd>CO2 measurement from the device, in ppm</dd>
  <dt>temperature</dt><dd>Temperature measurement from the device, in °C</dd>
  <dt>humidity</dt><dd>Humidity measurement from the device, in %. Your device might not have a humidity sensor. In this case, the humidity is always 0 (zero).</dd>
  </dl>

  <a id="co2mini-attr"><b>Attributes</b></a>
  <ul>
    <li><a id="co2mini-attr-disable">disable</a><br>
      If set to 1, the device is disconnected.
	</li>
    <li><a id="co2mini-attr-updateTimeout">updateTimeout</a><br>
	If there is no update from the co2mini server after <tt>updateTimeout</tt> seconds, the module disconnects and connects again. The default value is 120 seconds. Normally, the server only sends data every minute, so the updateTimeout should be greater than that.
	</li>
	<li><a id="co2mini-attr-device">device</a><br>
	This is the device node, like /dev/co2mini0. It only needs to be set if FHEM controls the co2mini server. Also see the attribute <tt>serverControl</tt>.
	</li>
	   <li><a id="co2mini-attr-serverControl">serverControl</a><br>
	   If this attribute is set to "fhem", then FHEM controls the co2mini server. This means that it is assumed that the sensor is directly connected to the FHEM server. The co2mini module then automatically starts the co2mini server and also connects to it.<br>
	   If this attribute is set to "external", then the co2mini module expects that the co2mini server is already running on the same server or on a remote server. In the latter case, the attribute <tt>serverIp</tt> has to be set accordingly. 
	</li>
	<li><a id="co2mini-attr-serverIp">serverIp</a><br>
	   This is the address of the computer where the co2mini server is running on. 
	</li>
	   <li><a id="co2mini-attr-serverPort">serverPort</a><br>
	   This is the port the co2mini server listens to. If <tt>serverControl</tt> is "fhem", then this can also be set to change the port which is used. I.e. the co2mini module will start the server with this port.
	</li>
	<li><a id="co2mini-attr-serverStartDelay">serverStartDelay</a><br>
	   If <tt>serverControl</tt> is "fhem", then the module waits for at least <tt>serverStartDelay</tt> seconds until it tried to connect to the server. The default value is 3 seconds. Higher values can lead to faster connection on slower systems, lower values might be ok on faster systems. If you have the impression that it takes long to connect, then try higher values first.
	</li>

  </ul>
</ul>

=end html
=cut