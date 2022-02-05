
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
  $hash->{AttrList} = "disable:0,1 showraw:0,1 updateTimeout device serverControl:fhem,external serverIp serverPort ".
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
  
	if(@a < 2) {
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

  $hash->{LAST_RECV} = time();
  queueConnectionCheck($hash);
}

sub Ready($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if main::AttrVal($name, "disable", 0 ) == 1;

    main::Log3 $name, 3, "Ready"; 

	#Start server
	$hash->{nextOpenDelay} = 10;
	serverStart($hash) if main::AttrVal($name, "serverControl", "fhem") eq "fhem";
    $hash->{helper}{buf} = "";
    return main::DevIo_OpenDev($hash, 1, "co2mini::OnConnect");
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

  main::Log3 $name, 5, "co2mini data received " . join(" ", @data);
  if($#data < 4) {
    main::Log3 $name, 3, "co2mini incoming data too short";
    return;
  }
  elsif($data[4] != 0xd) {
    main::Log3 $name, 3, "co2mini unexpected byte 5";
    return;
  }
  elsif((($data[0] + $data[1] + $data[2]) & 0xff) != $data[3]) {
    main::Log3 $name, 3, "co2mini checksum error";
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
  } elsif($item == 0x44) {
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
    main::Log3 $name, 1, "co2mini network error or disconnected: $!";
  }

  if(!defined($readlength)) {
    if($!{EAGAIN} or $!{EWOULDBLOCK}) {
      # This is expected, ignore it
    } else {
		#This only seems to happen if the connection is broken. Let's try
		#to restart	
        main::Log3 $name, 1, "co2mini device error or disconnected: $!";
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
	my $serverPort = $main::attr{$name}{serverPort};
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

  main::Log3 $name, 3, "CheckConnection";
 
  return undef unless main::ReadingsVal($name, "state", "") eq "connected";

  my $lastRecvDiff = (time() - $hash->{LAST_RECV});
  my $updateInt = main::AttrVal($name,'updateTimeout',120);
  
  # give it 20% tolerance. sticking hard to updateInt might fail if the fhem timer gets delayed for some seconds
  if ($lastRecvDiff > ($updateInt * 1.2)) {
    main::Log3 $name, 3, "CheckConnection: Connection lost! Last data from sensor received $lastRecvDiff s ago";
    main::DevIo_Disconnected($hash);
	#Setting state "disconnected" does not create an event in DevIo
	main::readingsSingleUpdate($hash,"state",'disconnected', 1);
    return undef;
  }
  main::Log3 $name, 4, "Connection still alive. Last data from co2mini received $lastRecvDiff s ago";
  
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
	
	delete $hash->{ServerPID};
	
	updateServerCommandLine($hash);
	my $pid = serverGetPid($hash, $hash->{commandLine});
	# Is a process with this command line already running? If yes then use this.
	if($pid && kill(0, $pid)) {
		main::Log3($hash, 1, 'Server already running with PID ' . $pid. '. We are using this process.');
		$hash->{ServerPID} = $pid;
		#InternalTimer(gettimeofday() + 0.1, 'HM485_LAN_openDev', $hash, 0);		
		return 'Server already running. (Re)Connected to PID '.$pid;
	};		
	#...otherwise try to start server
	system($hash->{commandLine} . '&');
	main::Log3($hash, 3, 'Start server with command line: ' . $hash->{commandLine});
	$pid = serverGetPid($hash, $hash->{commandLine});
	if(!$pid) {
		return 'Server could not be started';
	}
	$hash->{ServerPID} = $pid;
	main::Log3($hash, 3, 'Serverd was started with PID: ' . $pid);
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
		main::Log3($name, 1, 'There is no server process with PID ' . $pid . '.');	
		return undef;
	};	
	if(!kill('TERM', $pid)) {
		main::Log3($name, 1, 'Can\'t terminate server with PID ' . $pid . '.');
		return undef;
	};	
	$hash->{ServerSTATE} = 'stopped';
	delete($hash->{ServerPID});
	main::Log3($name, 3, 'HM485d with PID ' . $pid . ' was terminated.');
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
  <a href="https://hackaday.io/project/5301-reverse-engineering-a-low-cost-usb-co-monitor">Reverse-Engineering a low-cost USB CO₂ monitor</a>.<br><br>

  Alternatively you can use a remote sensor with the <tt>co2mini_server.pl</tt> available at <a href="https://github.com/henryk/fhem-co2mini">https://github.com/henryk/fhem-co2mini</a>.
  This script needs to be started with two arguments: the device node of the co2mini device and a port number to listen on. It will then listen on this port and accept connections from clients.
  Clients get a stream of decrypted messages from the CO2 monitor (that is: 5 bytes up to and including the 0x0D each).
  When configuring the FHEM module to connect to a remote <tt>co2mini_server.pl</tt>, simply supply <tt>address:port</tt> instead of the device node.<br><br>

  Notes:
  <ul>
    <li>FHEM, or the user running <tt>co2mini_server.pl</tt>, has to have permissions to open the device. To configure this with udev, put a file named <tt>90-co2mini.rules</tt>
        into <tt>/etc/udev/rules.d</tt> with this content:
<pre>ACTION=="remove", GOTO="co2mini_end"

SUBSYSTEMS=="usb", KERNEL=="hidraw*", ATTRS{idVendor}=="04d9", ATTRS{idProduct}=="a052", GROUP="plugdev", MODE="0660", SYMLINK+="co2mini%n", GOTO="co2mini_end"

LABEL="co2mini_end"
</pre> where <tt>plugdev</tt> would be a group that your process is in.</li>
  </ul><br>

  <a name="co2mini_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; co2mini [devicenode or address:port]</code><br>
    <br>

    Defines a co2mini device. Optionally a device node may be specified, otherwise this defaults to <tt>/dev/co2mini0</tt>.<br>
    Instead of a device node, a remote server can be specified by using <tt>address:port</tt>.<br><br>

    Examples:
    <ul>
      <code>define co2 co2mini</code><br>
    </ul>
    Example (network):
    <ul>
      <code>define co2 co2mini raspberry:23231</code><br>
    </ul>
    (also: on the host named <tt>raspberry</tt> start a command like <tt>co2mini_server.pl /dev/co2mini0 23231</tt>)
  </ul><br>

  <a name="co2mini_Readings"></a>
  <b>Readings</b>
  <dl><dt>co2</dt><dd>CO2 measurement from the device, in ppm</dd>
    <dt>temperature</dt><dd>temperature measurement from the device, in °C</dd>
    <dt>humidity</dt><dd>humidity measurement from the device, in % (may not be available on your device)</dd>
  </dl>

  <a name="co2mini_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li>disable<br>
      1 -> disconnect</li>
    <li>showraw<br>
      1 -> show raw data as received from the device in readings of the form raw_XX</li>
  </ul>
</ul>

=end html
=cut