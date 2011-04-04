#!/usr/bin/env perl
#
# lxc - Wrapper around lxc utils to make managing containers easier
# Copyright © 2011 Shoptime Software
#
# This package is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This package is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this package; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

use warnings;
use strict;
use 5.010;

use Carp;
use Config::IniFiles;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use LXC::Commands;
use Path::Class;
use Pod::Usage;
use Sysadm::Install qw(ask);

our $VERSION = '0.1.0';



my (%opt);

# If running the 'exec' command, hide the command from our option parsing
my @exec_args;
if ( scalar @ARGV > 2 && $ARGV[1] eq 'exec' ) {
    @exec_args = splice(@ARGV, 2);
}

if (!GetOptions(\%opt,
    'help|?',
    'version',

    # Other options will go here, as individual commands want them

    # Only used by 'create'
    'm|mirror=s',
    'n|no-start',
    't|template=s',
    'u|user-from-host',
)) {
    pod2usage(-exitval => 1, -verbose => 0);
}

push @ARGV, @exec_args;


# Actions that don't involve a command
pod2usage(-exitval => 0, -verbose => 1) if $opt{help};
if ( $opt{version} ) {
    system('lxc-version');
    print "lxc control script: $VERSION\n";
    exit 0;
}


# Configure app
my $cfg;
my @searchpath = (
    '/etc/lxc/lxc-simple.ini',
    "$FindBin::Bin/lxc-simple.ini",
);
foreach my $filename ( @searchpath ) {
    if ( -f $filename ) {
        $cfg = Config::IniFiles->new(-file => $filename);
        last;
    }
}

my $app = LXC::Commands->new(
    lxc_dir    => Path::Class::dir($cfg ? $cfg->val('paths', 'lxc_dir') : '/var/lib/lxc'),
);


# Run command!
my $name    = shift;
my $command = shift;

if ( defined $command ) {
    pod2usage(-exitval => 0, -verbose => 0) unless $name;
}
else {
    # For commands that don't have to operate on containers (e.g. 'status')
    $command = $name;
    $name    = undef;
}

unless ($> == 0 || $< == 0) { die "You must be root\n" }

given ( $command ) {
    when ( 'create' ) {
        $app->create(
            name           => $name,
            install_user   => $opt{u},
            mirror         => $opt{m},
            start          => !$opt{n},
            template       => $opt{t},
        );
    }
    when ( 'destroy' ) {
        $app->check_valid_container($name);

        my $input = ask("Are you sure you want to destroy '$name'?", 'n');
        die "Aborted\n" unless $input =~ m{^y}i;

        $app->destroy(
            name => $name,
        );
    }
    when ( 'start' ) {
        $app->start(
            name => $name,
        );
    }
    when ( 'stop' ) {
        $app->stop(
            name => $name,
        );
    }
    when ( 'restart' ) {
        $app->restart(
            name => $name,
        );
    }
    when ( 'enter' ) {
        $app->enter(
            name => $name,
        );
    }
    when ( 'console' ) {
        $app->console(
            name => $name,
        );
    }
    when ( 'exec' ) {
        $app->enter(
            name    => $name,
            command => \@ARGV,
        );
    }
    when ( 'status' ) {
        $app->status(
            name => $name,
        );
    }
    default {
        die "No such command.\n\nTry $0 --help\n";
    }
}


__END__

=head1 NAME

lxc - Wrapper around lxc utils to make managing containers easier

=head1 SYNOPSIS

    lxc [name] [command]     # When operating on a container
    lxc [command]            # For some commands

    Commands:

     lxc [name] create [-u] --template=[lucid|maverick|etc...]
     lxc [name] destroy
     lxc [name] start|stop|restart
     lxc [name] enter
     lxc [name] exec command [args]
     lxc [name] console
     lxc [name] status
     lxc status

=head1 DESCRIPTION

C<lxc> wraps around the low-level commands for controlling linux containers, to
make it easier to manage containers for the common case - which is creating
containers that work in a similar fashion to vservers or jails.

=head1 OPTIONS

=over 4

=item B<-h|--help>

Display this documentation.

=item B<--version>

Display the version of this script, and the version of C<lxc> installed on your
system.

=back

=head1 OPTIONS FOR C<create>

=over 4

=item B<-m|--mirror>

Specify an apt mirror to use inside the container (regretfully, not used for
downloading the container yet - upstream needs to offer this feature).

=item B<-n|--no-start>

Don't start the container once created (the default is to start it).

=item B<-t|--template>

Specify an LXC template to use to create the container with. This is passed
through to C<lxc-create>.

=item B<-u|--user-from-host>

If you invoke C<create> via sudo and use this option, it will bind mount /home
into the container and create a user account for you.

The user account will have the same password as your account on the host.

=back

=head1 AUTHOR

Shoptime Software and others; see CREDITS

=cut
