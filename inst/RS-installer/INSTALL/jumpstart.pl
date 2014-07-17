#!/usr/bin/perl -w

use strict;
use lib "/jumpstart/lib";
use lib "/profiles";
use Socket;
use Net::Netmask;
use vars qw(%environ @disks @idedisks $hpsmartarray);
my (%net, %scsi, %pci_table);

use POSIX qw/setsid/;

setsid() or warn "setsid: failed\n\n";
ioctl STDIN, 0x540E, 0 or warn "Set controlling tty failed\n\n";
# 0x540E == TIOCSTTY on linux - TODO fixme

@idedisks = ('hda' .. 'hdz');
@disks = ('sda' .. 'sdz');
$hpsmartarray = 0; # Is this box using a HP Smart Array?

# from the profile
use vars qw(@diskconfig @liloconfig $diskimage $etcdir $motd_tag $primary_iface);

$|++;
# we ignore steps that begin with ! 
my @js_steps = qw(
 banner

 check_integrity
 get_environ
 load_netmodules
 set_ip
 
 optional_shell
 
 ping_and_sleep

 run_installer
);

$ENV{PATH}="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/usr/local/sbin";
my $step;
no strict 'refs';

run_steps(@js_steps);
exit(0);

sub run_steps {
    my @steps = @_;
    foreach $step (@steps) {
        next if $step =~ /^!/;
        set_status("jumping -- $step");
        open(UPTIME, "<", "/proc/uptime") or die "uptime: $!";
        my $uptime = <UPTIME>;
        close UPTIME;
        chomp $uptime;
        displaybold("($uptime) * $step\n");

        if (defined $ENV{"BEFORE_$step"}) {
            exec( $ENV{"BEFORE_$step"} ) || warn "Failed to exec BEFORE_$step : $!";
            crapout("Failed while trying to run " .  $ENV{"BEFORE_$step"} . "\n");
        }


        if (defined &$step) {
            &$step();
        } else {
            &warning("WARNING: Could not find step: $step in $0\n");
        }

        if (defined $ENV{"AFTER_$step"}) {
            exec( $ENV{"AFTER_$step"} ) || warn "Failed to exec AFTER_$step : $!";
            crapout("Failed while trying to run " .  $ENV{"AFTER_$step"} . "\n");
        }
       
    }
}

sub figlet {
    my $msg = shift;
    print "\n\n";
    system("figlet", $msg);
    print "\n\n";
}

sub check_integrity {
    my $version = `uname -r`;
    chomp($version);

    unless (-d "/lib/modules/$version") {
        figlet("Missing modules");
        print "This kernel version is $version, but there's no /lib/modules/$version directory. Are you using the right installer kernel?\n\n";
        sleep(300);
        exit(1);
    }
}

sub get_pci_mappings {
    my %pciid_module;

    open my $pcitable, "</modules/pcitable" or die "pcitable: $!";
    while (<$pcitable>) {
        next if /^#/;
        next if /Card:/;
        chomp;
        s/\b0x//g;
        my @fields = split;
        unless (@fields == 3 or @fields == 5) {
            warning("'$_' can't parse");
            next;
        }
        my $modname = pop @fields;
        $modname =~ s/^"//; $modname =~ s/"$//;

        $pciid_module{"$fields[0]:$fields[1]"} = $modname;
        if (@fields > 5) {
            $pciid_module{"$fields[2]:$fields[3]"} = $modname;
        }
    }
    close $pcitable;

    return \%pciid_module;
}

sub get_module_for {
    my ($pci_ids, $id) = @_;
    my $module = $pci_ids->{$id};
    return $module if defined $module;

    warning("Unknown PCI ID: $id");
    return "Unknown-$id";
}

# loading the right modules
sub load_modules {
    my $pci_ids = get_pci_mappings();
    %pci_table = %{$pci_ids};
    my @pci = `lspci -n`;
    for (@pci) {
        my ($class, $id) = (split)[2, 3];
        $class =~ s/:$//;

        my $num_class = hex($class);
        if ($num_class >=0x100 and $num_class <0x200) {
            $scsi{ get_module_for($pci_ids, $id) }++;
        } elsif ($num_class == 0x200) {
            $net{ get_module_for($pci_ids, $id) }++;
        }
        # TODO ide ?
    }

    modprobe("net", "e1000") if grep {/^e1000$/} keys %net;
    modprobe("net", "$_") for keys %net;
    modprobe("scsi", "$_") for keys %scsi;
    modprobe("scsi disks", "sd_mod") if %scsi;
}

sub modprobe {
    my ($type, $module) = @_;
    return if $module =~ /^Unknown/;

    print "----> Loading $type module: $module\n";
    system("modprobe $module");
}

sub optional_shell {
    print "Press <ENTER> if you want a shell...";
    system("lsmod") if $environ{hostname} =~ /test$/;
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
    open(ONE, "<", "/proc/1/environ") or 
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

sub set_ip {
    my($ip,$boothost,$gateway,$netmask) = split(/:/,$environ{ip});
    $environ{myip}=$ip;
    $environ{boothost}=$boothost;
    $environ{gateway}=$gateway;
    $environ{netmask}=$netmask;

    my $block = new Net::Netmask($ip,$netmask);
    $environ{base}=$block->base;
    my $broadcast = $environ{broadcast}=$block->broadcast;

    display( "Setting IP address to $ip\n");
    run_local("/sbin/ifconfig", "eth0", "inet", $ip,
        "netmask",$netmask, "broadcast", $broadcast);
    run_local("/sbin/route", "add", "default", "gw", $gateway);
    display( "Setting 'boothost' in /etc/hosts\n");
    add_unique_line("/etc/hosts","$boothost boothost");
}

sub crapout {
    set_status("jumptart error: @_\n");
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

sub add_unique_line {
    my($name,@lines) = @_;
    my %hash;
    if (open(UNIQUE,"<$name")) {
	while (<UNIQUE>) {
	    chomp;
	    $hash{$_}++;
	}
	close UNIQUE;
    }
    open(UNIQUE,">>$name") || crapout("Could not append $name: $!");
    foreach (@lines) {
	unless (defined $hash{$_}) {
	    &display("Adding to $name: $_\n");
	    print UNIQUE "$_\n";
	}
    }
    close UNIQUE;
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
    display( `cat /INSTALL/banner.ans` );
    sleep 5;
}

sub run_installer {
    system('echo "GET /jumpstart/installer.cgi" | nc boothost 9999 >/INSTALL/installer.pl');
    eval qq(require "/INSTALL/installer.pl");
    crapout($@) if $@;
}

    
sub ping_and_sleep {
    my $eth1 = 0;
    system "ping -c 1 boothost";
    if ($? != 0) {
        sleep 10;
        system "ping -c 1 boothost";
    }
    if ($? != 0) {
        sleep 10;
        system "ping -c 1 boothost";
    }

    if ($? != 0) {
        print "ERROR: Can't ping boothost\n";
        $eth1 = 1;
        run_local("/sbin/ifconfig", "eth0", "down");
        run_local("/sbin/ifconfig", "eth1", "inet", $environ{myip},
            "netmask", $environ{netmask}, "broadcast", $environ{broadcast});
        run_local("/sbin/route", "add", "default", "gw", $environ{gateway});

        print "INFO: Trying eth1\n";
        system "ping -c 1 boothost";
        if ($? != 0) {
            sleep 15;
            system "ping -c 1 boothost";
        }
    } else {
        $primary_iface = "eth0";
    }

    if ($? != 0) {
        print "ERROR: couldn't ping boothost using eth0 or eth1\n";
        system("sh");
    } elsif ($eth1) {
        print "WARNING: Using eth1!\n";
        $primary_iface = "eth1";
    }

    print "\n";
}

sub set_status {
   open(STATUS,">/tmp/status") || return;
   print STATUS "@_\n";
   close STATUS;
}
