#!/usr/bin/perl -w

use strict;
use lib "/jumpstart/lib";
use Socket;
use Net::Netmask;
use vars qw(%environ );

$|++;
# we ignore steps that begin with ! 
my @steps = qw(
 banner
 get_environ
 remount_root

 set_ip_fake_and_ping
 optional_shell


 bannerdone
);

$ENV{PATH}="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/usr/local/sbin";
my $step;
no strict 'refs';
foreach $step (@steps) {
    next if $step =~ /^!/;
    open(UPTIME,"/proc/uptime") or die "uptime: $!";
    my $uptime = <UPTIME>;
    close UPTIME;
    chomp $uptime;
    displaybold("($uptime) * $step\n");
    if (defined &$step) {
        &$step();
    } else {
        &warning("WARNING: Could not find step: $step in $0\n");
    }
}


sub print_to_serial {
  open(SERIAL,">/dev/ttyS0");
  print SERIAL "JUMPSTART SERIAL INFO: This is serial ttyS0\n";
  close SERIAL;
  open(SERIAL,">/dev/ttyS1");
  print SERIAL "JUMPSTART SERIAL INFO: This is serial ttyS1\n";
  close SERIAL;
}

sub optional_shell {
    print "Press <ENTER> if you want a shell...";
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 5;
        my $buffer;
        my $blah = sysread STDIN, $buffer, 1;
        alarm 0;
    };
    if ($@) {
        # propagate unexpected errors
        die unless $@ eq "alarm\n";
        print "\n";
    } else {
        # a shell
        system("sh");
    }
}

sub get_environ {
    open(ONE,"/proc/1/environ") or 
        crapout("Could not open /proc/1/environ: $!");
    my $buffer;
    read ONE,$buffer,4096,0;
    my @buffer = split(/\x00/,$buffer);
    my %buffer;
    display("parsing /proc/1/environ\n");
    foreach (@buffer) {
        display("  $_\n");
        my ($a,$b) = split(/=/, $_, 2);
        $buffer{$a}=$b;
    }

    unless($buffer{Jump}) {
        crapout("Could not determine Jump= profile name - not jumpstarting.");
    }

    unless($buffer{hostname}) {
        crapout("Could not determine hostname=  - not jumpstarting.");
    }

    unless($buffer{ip}) {
        crapout("Could not determine IP address; pxeboot did not supply it?");
    }

    my $date = `date`; chomp $date;
    $buffer{"date"} = $date;

    %environ = %buffer;
}


sub set_ip_fake_and_ping {
    my($eth);
    my($ifconfig);
    my($mac);
    my($ip);
    my(@run);
    my(@if) = `cat /proc/net/dev`;
    my(@eth);
    my(@display);
    foreach (@if) {
      if (/(eth\d):/) {
        push(@eth,$1);
      }
    }

    foreach $eth (@eth) {
      display("Getting ifconfig $eth\n");
      $ifconfig = `ifconfig $eth`;
      $ifconfig =~ s/\s+/ /g;
      display("$ifconfig\n");
      if ($ifconfig =~ m/HWaddr ([0-9ABCDEF:]+) /) {
         $mac = $1;
         $ip = $mac ;    
         $ip =~ s/^[0-9ABCDEF][0-9ABCDEF]:[0-9ABCDEF][0-9ABCDEF]:[0-9ABCDEF][0-9ABCDEF]:/0A:/;
         $ip =~ s/:/./g;
         $ip =~ s/\b([0-9a-fA-F]+)\b/ hex $1 /ge;
         push(@display,"JUMPSTART IF $eth MAC $mac IP $ip\n");
         run_local("/sbin/ifconfig",$eth,"inet",$ip,"netmask","255.0.0.0","broadcast","10.255.255.255","up");
      }
    }
    while(1) {
      print_to_serial();
      foreach(@display) { display($_ . "\n"); }
      run_local("/bin/ping","-c",5,"-n","-i","10","10.254.254.254");
      optional_shell();
    }
    displaybold("Why did we return from our pings?");
    crapout("unexpected");
}


sub remount_root {
    display("Remounting / for read/write\n");
    run_local("mount","-o","remount","-o","rw","/");
    unless (-w "/") { crapout("Remounting / as read-write failed - / is not writable");}
}


sub crapout {
    displaybold("ERROR: ");
    print @_, "\n";
    optional_shell();
    die @_;
}

sub warning {
    # May want this to go to all terminals - ie, display, serial, etc.
    print STDERR @_;
}

sub display {
    print @_;
}

sub displaybold {
    print "[1m";
    print @_;
    print "[0m";
}

sub run_local {
    my(@list) = @_;
    my $pwd = `pwd`;
    chomp $pwd;
    print "$pwd # @list\n";
    system @list;
    my $exit_value  = $? >> 8;
    my $signal_num  = $? & 127;
    my $dumped_core = $? & 128;
    print "(Exit=$exit_value)\n" if ($exit_value);
    print "(Signal $signal_num)\n" if ($signal_num);
    print "(Dumped core)\n" if ($dumped_core);
    return $exit_value;
}


sub banner {
    displaybold( "Now running: $0\n");
    sleep 1;
}




sub bannerdone {
    display("\n\nDONE RUNNING: $0\n");
}

