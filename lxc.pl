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
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use LXC::Commands;
use Pod::Usage;
use Sysadm::Install qw(ask);

our $VERSION = '0.1.0';



my (%opt);

if (!GetOptions(\%opt,
    'help|?',
    'version',

    # Other options will go here, as individual commands want them

    # Only used by 'create'
    'm|mirror=s',
    't|template=s',
    'u|user-from-host',
)) {
    pod2usage(-exitval => 1, -verbose => 0);
}


# Actions that don't involve a command
pod2usage(-exitval => 0, -verbose => 1) if $opt{help};
if ( $opt{version} ) {
    system('lxc-version');
    print "lxc control script: $VERSION\n";
    exit 0;
}


# Run command!
my $name    = shift;
my $command = shift;

if ( defined $command ) {
    pod2usage(-exitval => 0, -verbose => 0) unless $name;
}
else {
    # For commands that don't operate on containers (e.g. 'status')
    $command = $name;
    $name    = undef;
}

unless ($> == 0 || $< == 0) { die "You must be root\n" }

given ( $command ) {
    when ( 'create' ) {
        LXC::Commands->create(
            name           => $name,
            install_user   => $opt{u},
            mirror         => $opt{m},
            template       => $opt{t},
        );
    }
    when ( 'destroy' ) {
        LXC::Commands->check_valid_container($name);

        my $input = ask("Are you sure you want to destroy '$name'?", 'n');
        die "Aborted\n" unless $input =~ m{^y}i;

        LXC::Commands->destroy(
            name => $name,
        );
    }
    when ( 'start' ) {
        LXC::Commands->start(
            name => $name,
        );
    }
    when ( 'stop' ) {
        LXC::Commands->stop(
            name => $name,
        );
    }
    when ( 'restart' ) {
        LXC::Commands->restart(
            name => $name,
        );
    }
    when ( 'enter' ) {
        LXC::Commands->enter(
            name => $name,
        );
    }
    when ( 'console' ) {
        LXC::Commands->console(
            name => $name,
        );
    }
    when ( 'status' ) {
        LXC::Commands->status(
            name => $name,
        );
    }
    when ( 'resync' ) {
        # TODO
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
     lxc [name] console
     lxc status
     lxc resync

=head1 DESCRIPTION

C<lxc> wraps around the low-level commands for controlling linux containers, to
make it easier to manage containers for the common case - which is creating
containers that work in a similar fashion to vservers or jails.

People often create many containers. When you do, what happens when you decided
that your containers should all have some package installed in them? It's a
pain to make such changes manually to each existing container. C<lxc> fixes
this by installing puppet in each container, and giving you a command
(C<lxc resync>) that will sync all containers with a puppet manifest you define.

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

=item B<-t|--template>

Specify an LXC template to use to create the container with. This is passed
through to C<lxc-create>.

=item B<-m|--mirror>

Specify an apt mirror to use inside the container (regretfully, not used for
downloading the container yet - upstream needs to offer this feature).

=item B<-u|--user-from-host>

If you invoke C<create> via sudo and use this option, it will bind mount /home
into the container and create a user account for you.

The user account will have the same password as your account on the host.

=back

=head1 AUTHOR

Shoptime Software and others; see CREDITS

=cut
