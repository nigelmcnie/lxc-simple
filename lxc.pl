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
    'a|autostart',
    'm|mirror=s',
    'n|no-start',
    't|template=s',
    'u|user-from-host',

    # Only used by 'resync'
    'a|all',
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
    puppet_dir => Path::Class::dir($cfg ? $cfg->val('paths', 'puppet_dir') : "$FindBin::Bin/puppet"),
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
            autostart      => $opt{a},
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
    when ( 'resync' ) {
        $app->resync(
            name => $name,
            all  => $opt{a},
        );
    }
    when ( 'autostart' ) {
        $app->autostart;
    }
    when ( 'stopall' ) {
        $app->stopall;
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

=head1 COMMANDS

=head2 lxc [name] create

Creates a new container. Will also start it unless you pass C<-n>.

You will probably want to use the template option to specify the distribution
your container should be.

Take note of C<-u> - it can be useful if you want to set up a container for
developing software in.

=head3 Options

=over 4

=item B<-a|--autostart>

Flag this container as one that should be automatically started on boot.

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

This option is useful when you want to create a container for developing
software in. You can use your IDE/editor setup/VCS that you have already
configured on the host, and the bind mount means the container can see all your
code.

=back

=head2 lxc [name] destroy

Destroys a container. You'll be asked to confirm first. This operation cannot
be undone!

=head2 lxc [name] start

Starts a container. It waits until networking is up in the container, which
means C<enter> will work.

=head2 lxc [name] stop

Gracefully shuts down a container (unlike the rather brutal L<lxc-stop>
command).

=head2 lxc [name] restart

Stops a container, if it's running, then starts it.

=head2 lxc [name] enter

Gives you a shell inside the container.

Under the hood, this is currently implemented with ssh, until kernels with
L<lxc-attach> support are widely available.

=head2 lxc [name] exec command [args]

Executes the command in the container.

=head2 lxc [name] console

Connects you to C<tty1> in the container.

Note that you can only do this from one place at a time, however this command
is just a layer over L<lxc-console>, so you could get more if you wanted.
However, in most cases, you'll just want to use L<lxc [name] enter> instead.

The one time this is useful is if networking is down inside the container.

=head2 lxc [name] status

Tells you the status of the container.

Currently, this is limited to whether it's running or not. This is just a
wrapper around L<lxc-info>.

=head2 lxc status

Tells you the status of all containers.

=head2 lxc [name] resync [-a]

Runs puppet in container(s). This actually has three variants:

=over 4

=item C<lxc [name] resync> - runs puppet in a container

=item C<lxc resync> - runs puppet in all running containers

=item C<lxc resync -a> - runs puppet in all containers, starting stopped ones
to run puppet in them, and stopping them again when done

=back

=head2 lxc autostart

Starts all containers that have a file called 'autostart' in their lxc config
directory (usually /var/lib/lxc/[name]).

This is most useful for starting containers automatically on boot.

=head2 lxc stopall

Stops all containers.

This is most useful for stopping containers automatically on shutdown.

=head1 AUTHOR

Shoptime Software and others; see CREDITS

=cut
