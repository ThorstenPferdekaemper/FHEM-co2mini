#!/usr/bin/perl

# Creates control file for co2mini

use IO::File;
use strict;
use warnings;

my @filelist2 = (
  "FHEM/.*.pm",
  "FHEM/lib/co2mini/.*",
);


# Can't make negative regexp to work, so do it with extra logic
my %skiplist2 = (
# "www/pgm2"  => ".pm\$",
);

# Read in the file timestamps
my %filetime2;
my %filesize2;
my %filedir2;
foreach my $fspec (@filelist2) {
  $fspec =~ m,^(.+)/([^/]+)$,;
  my ($dir,$pattern) = ($1, $2);
  my $tdir = $dir;
  opendir DH, $dir || die("Can't open $dir: $!\n");
  foreach my $file (grep { /$pattern/ && -f "$dir/$_" } readdir(DH)) {
    next if($skiplist2{$tdir} && $file =~ m/$skiplist2{$tdir}/);
    my @st = stat("$dir/$file");
    my @mt = localtime($st[9]);
    $filetime2{"$tdir/$file"} = sprintf "%04d-%02d-%02d_%02d:%02d:%02d",
                $mt[5]+1900, $mt[4]+1, $mt[3], $mt[2], $mt[1], $mt[0];
				
	open(FH, "$dir/$file");
    my $data = join("", <FH>);
    close(FH);			
					
    $filesize2{"$tdir/$file"} = length($data); # $st[7];
    $filedir2{"$tdir/$file"} = $dir;
  }
  closedir(DH);
}


 my $fname = "controls_co2mini.txt";
 my $controls = new IO::File ">$fname" || die "Can't open $fname: $!\n";
 if(open(ADD, "fhemupdate.control")) {
   while(my $l = <ADD>) {
     print $controls $l;
   }
   close ADD;
 }

my $cnt;
foreach my $f (sort keys %filetime2) {
  my $fn = $f;
  $fn =~ s/.txt$// if($fn =~ m/.pl.txt$/);
  # print FH "$filetime2{$f} $filesize2{$f} $fn\n";
  print $controls "UPD $filetime2{$f} $filesize2{$f} $fn\n"
}

close $controls;
