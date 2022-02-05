#!/usr/bin/perl -w
# 

## Heavily based on http://docstore.mik.ua/orelly/perl/cookbook/ch17_14.htm

use strict;
use POSIX;
use IO::Socket;
use IO::Select;
use Socket;
use Fcntl;
use Getopt::Long;
use Pod::Usage;

$SIG{PIPE} = "IGNORE";

my $device = '/dev/co2mini0';
my $port = 41042;  #A052
my $interval = 60;  
my $verbose = 2;
my $help;

GetOptions (
		'device=s'  => \$device,    # The device, like /dev/co2mini
		'port=i'    => \$port,      # The port the server listens to
		'interval=i' => \$interval, # Min. interval in seconds between two measurements
		'verbose=i' => \$verbose,   # 0 -> nothing, 1 -> Startup/Shutdown/Errors, 
									# 2 -> Client add/remove, 3 -> Sent data, 4 -> Received data 
		'help' => \$help,
);		

pod2usage( -verbose => 99, -sections => "NAME|SYNOPSIS|OPTIONS|DESCRIPTION" ) if ($help);


die "Need two arguments: device file and port" if !defined($device) or !defined($port);

# Listen to port.
my $server = IO::Socket::INET->new(LocalPort => $port,
								   Reuse     => 1,	
                                   Listen    => 10 )
  or die "Can't make server socket: $@\n";
nonblock($server);

# Result of printf("0x%08X\n", HIDIOCSFEATURE(9)); in C
my $HIDIOCSFEATURE_9 = 0xC0094806;

# Key retrieved from /dev/random, guaranteed to be random ;-)
my $key = "\x86\x41\xc9\xa8\x7f\x41\x3c\xac";

my $deviceconn;
my $select;


sub log2($$) {
	my ($severity, $message) = @_;
	return if $severity > $verbose;
	print $message."\n";	
};	


sub mainloop {
    # begin with empty buffers
    my %outbuffer = ();
	my %lastSentTime = ();
	my $now;

    $select = IO::Select->new($server);

    sysopen($deviceconn, $device, O_RDWR | O_APPEND | O_NONBLOCK) or return "Error opening " . $device;

    # Send a FEATURE Set_Report with our key
    ioctl($deviceconn, $HIDIOCSFEATURE_9, "\x00".$key) or return "Error establishing connection to " . $device;

    $select->add($deviceconn);
	log2(1,"Opened $device");

    # Main loop: check reads/accepts, check writes, check ready to process
    while (1) {
        my $client;
        my $rv;

        # check for new information on the connections we have

        # anything to read or accept?
        foreach $client ($select->can_read(1)) {

            if ($client == $server) {
                # accept a new connection

                $client = $server->accept();
                $select->add($client);
                nonblock($client);
				log2(2,"New client accepted ".$client->peerhost());
				#Reset last sent time so that the new client gets a message immediately
				%lastSentTime = ();
            } elsif ($client == $deviceconn) {
                my $buf;
                my $readlength = sysread($deviceconn, $buf, 8);
                return "Could not read from device" if $readlength != 8;
			
				#Ignore stuff we cannot interpret
				#42 - Temperature
				#44 - Humidity
				#50 - CO2
				next unless($buf =~ m/^[\x42\x44\x50]/);
				
				log2(4,"Received data from $device");
				
				# decrypt fix PFE	
				# my @data = co2mini_decrypt($key, $buf);
				my @data = map { ord } split //, $buf;
				
                if($data[4] != 0xd or (($data[0] + $data[1] + $data[2]) & 0xff) != $data[3]) {
                    return "co2mini wrong data format received or checksum error";
                }		
				
				#Check/store send interval by message type
				$now = time();
				next if(defined($lastSentTime{$data[0]}) && $now - $lastSentTime{$data[0]} < $interval);
				$lastSentTime{$data[0]} = $now;

                my $msg = join("", map { chr } @data[0 .. 4]);

                foreach $client ($select->handles()) {
                    next if $client == $server;
                    next if $client == $deviceconn;
                    $outbuffer{$client} = ($outbuffer{$client} // "") . $msg;
                }
            }
        }

        # Buffers to flush?
        foreach $client ($select->can_write(0)) {
            # Skip this client if we have nothing to say
            next unless exists $outbuffer{$client};

            $rv = $client->send($outbuffer{$client}, 0);
            if ( ($rv // -1) == length $outbuffer{$client} ||
                $! == POSIX::EWOULDBLOCK) {
                substr($outbuffer{$client}, 0, $rv) = '';
                delete $outbuffer{$client} unless length $outbuffer{$client};
				log2(3,"Sent data to client ".$client->peerhost());
            } else {
                # Couldn't write all the data, and it wasn't because
                # it would have blocked.  Shutdown and move on.
				log2(2,"Removing client ".$client->peerhost());
                delete $outbuffer{$client};

                $select->remove($client);
                close($client);
                next;
            }
        }
    }
}


while(1) {
    my $errmsg = mainloop();
    log2(1,$errmsg);
    log2(1,"Cleaning up and restarting");
    # Cleanup, re-start the main loop
    my $client;
    foreach $client ($select->handles()) {
	next if $client == $server;
        close($client);
    }
    sleep 1;
}

# Input: string key, string data
# Output: array of integers result
sub
co2mini_decrypt {
  my @key = map { ord } split //, shift;
  my @data = map { ord } split //, shift;
  my @offset = (0x84,  0x47,  0x56,  0xD6,  0x07,  0x93,  0x93,  0x56);
  my @shuffle = (2, 4, 0, 7, 1, 6, 5, 3);
  
  my @phase1 = map { $data[$_] } @shuffle;
  
  my @phase2 = map { $phase1[$_] ^ $key[$_] } (0 .. 7);
  
  my @phase3 = map { ( ($phase2[$_] >> 3) | ($phase2[ ($_-1+8)%8 ] << 5) ) & 0xff; } (0 .. 7);
  
  my @result = map { (0x100 + $phase3[$_] - $offset[$_]) & 0xff; } (0 .. 7);
  
  return @result;
}


# nonblock($socket) puts socket into nonblocking mode
sub nonblock {
    my $socket = shift;
    my $flags;
    
    $flags = fcntl($socket, F_GETFL, 0)
            or die "Can't get flags for socket: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
            or die "Can't make socket nonblocking: $!\n";
}

1;


=head1 NAME

co2mini_server.pl

=head1 SYNOPSIS

co2mini_server.pl [options]

=head1 DESCRIPTION

Server for co2mini devices

=head1 OPTIONS

=over 4

=item B<-help>

Print the help and exit

=item B<-device>

The device file, like /dev/co2mini0, which is the default

=item B<-port>

The port the server listens to

=item B<-interval>

Minimum interval in seconds between two measurements

=item B<-verbose>

Verbosity or log level

=over 1

=item 0 -> nothing

=item 1 -> Startup/Shutdown/Errors

=item 2 -> Client add/remove

=item 3 -> Sent data

=item 4 -> Received data 

=back

=back

=cut