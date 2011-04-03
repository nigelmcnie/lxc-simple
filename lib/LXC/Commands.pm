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

package LXC::Commands;
use warnings;
use strict;

use File::Slurp;
use Passwd::Unix;
use Sysadm::Install qw(tap);

=head1 NAME

LXC::Commands - commands for LXC

=head1 DESCRIPTION

Contains routines that back the LXC commands. Normally, you would access these
through the 'lxc' script, but you can include this module and use them directly
if you wish.

=head1 METHODS

=cut


=head2 create

Creates a new container.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to create.

=item install_user

If true, bind mounts /home into the container. Also, if this script was invoked
by C<sudo>, it creates an account and group in the container for that user,
using the same details as on the host (e.g. same password).

=item mirror

The mirror to use to download packages.

=item template

The template to use to create the container (see C<lxc-create>'s C<--template>
option).

=back

=cut

sub create {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify a name for the container to be created\n";

    system('lxc-create',
        '-n', $name,                    # TODO: check for invalid name first?
        '-f', '/etc/lxc/lxc.conf',      # TODO: this is for networking stuff
        '-t', $args{template} // 'ubuntu',
    ) == 0
        or die "lxc-create failed with exit code $?\n";

    # TODO /var/lib/lxc should be configurable
    my $lxc_root          = '/var/lib/lxc/';
    my $container_cfgroot = $lxc_root . $name . '/';
    my $container_root    = $lxc_root . $name . '/rootfs/';

    # Install our own /etc/network/interfaces
    my $interfaces_content = q(
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    # NOTE: if you're making your own interface definition, leave this line in
    # place so that 'lxc [name] enter' will work
    up ip a s dev eth0 | grep 'inet\W' | awk '{print $2}' | cut -f 1 -d '/' > /lxc-ip
);
    write_file($container_root . 'etc/network/interfaces', $interfaces_content);

    # Bindmount homedir and install user account if asked for
    if ( $args{install_user} ) {
        append_file($container_cfgroot . 'fstab',
            sprintf("/home           %s         auto bind 0 0\n", $container_root . 'home'));

        # TODO naturally, we could grab this information from a config file
        if ( exists $ENV{SUDO_USER} ) {
            my $user  = $ENV{SUDO_USER};
            my $group = $ENV{SUDO_USER};

            my $hostpw = Passwd::Unix->new(
                passwd => '/etc/passwd',
                shadow => '/etc/shadow',
                group  => '/etc/group',
                backup => 0,
            );
            my @userinfo  = $hostpw->user($user);
            my @groupinfo = $hostpw->group($group);

            my $containerpw = Passwd::Unix->new(
                passwd => $container_root . 'etc/passwd',
                shadow => $container_root . 'etc/shadow',
                group  => $container_root . 'etc/group',
                backup => 0,
            );
            $containerpw->user($user, @userinfo);
            $containerpw->group($group, @groupinfo);
        }
        else {
            print "Could not establish what user to install, skipping\n";
        }
    }

    if ( $args{mirror} ) {
        my $mirror = $args{mirror};
        my $apt_sources_file = $container_root . 'etc/apt/sources.list';

        my $contents = read_file($apt_sources_file);
        $contents =~ s/archive.ubuntu.com/$mirror/g;
        write_file($apt_sources_file, $contents);

        system('chroot', $container_root, 'apt-get', 'update');
    }

    system('chroot', $container_root, 'apt-get', 'install', '-y', '--force-yes', 'gpgv');
    system('chroot', $container_root, 'apt-get', 'update');
}


=head2 destroy

Destroys a container, stopping it first if necessary.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to destroy.

=back

=cut

sub destroy {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify what container to destroy\n";
    $class->check_valid_container($name);

    if ( $class->status(name => $name, brief => 1) eq 'running' ) {
        $class->stop(name => $name);
    }

    print "Destroying test... ";
    system('lxc-destroy',
        '-n', $name,
    );
    print "done\n";
}


=head2 start

Starts a container.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to start.

=back

=cut

sub start {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify what container to start\n";
    $class->check_valid_container($name);

    die "Container '$name' IS started\n" if $class->status(name => $name, brief => 1) eq 'running';

    print "Starting $name... ";
    system('lxc-start',
        '-n', $name,
        '-d',
    );
    system('lxc-wait',
        '-n', $name,
        '-s', 'RUNNING',
    );
    print "done\n";
}


=head2 stop

Stops a container.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to stop.

=back

=cut

sub stop {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify what container to stop\n";
    $class->check_valid_container($name);

    die "Container '$name' IS stopped\n" if $class->status(name => $name, brief => 1) eq 'stopped';

    print "Stopping $name... ";
    system('lxc-stop',
        '-n', $name,
    );
    system('lxc-wait',
        '-n', $name,
        '-s', 'STOPPED',
    );
    print "done\n";
}


=head2 enter

Gives you a shell in the container.

Note: until C<lxc-attach> is implemented in the kernel (which it still wasn't
as of 2.6.38rc1), we hack this functionality by using ssh instead.

For that we need to know the IP of the guest, which it provides by dumping it
to /lxc-ip (in the container) when the interface is brought up.

If ssh isn't running or the IP isn't written to that file, we can't get a
shell. It would be much nicer if lxc-attach worked!

Takes a hash with the following keys:

=over 4

=item name

The name of the container to get a shell in.

=back

=cut

sub enter {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify what container to get a shell in\n";
    $class->check_valid_container($name);

    die "Container '$name' is stopped\n" if $class->status(name => $name, brief => 1) eq 'stopped';

    my $ip_file = "/var/lib/lxc/$name/rootfs/lxc-ip";
    die "Could not determine container IP to ssh to (maybe ssh hasn't finished starting in the container?)\n" unless -f $ip_file;
    my $ip = read_file($ip_file);
    chomp $ip;
    die "No IP available for container '$name'" unless $ip;
    die "Could not determine container IP to ssh to" unless $ip =~ m{^\d+\.\d+\.\d+\.\d+$};

    print "Default password is 'root'\n";
    system('ssh',
        '-o', 'StrictHostKeyChecking=no',
        'root@' . $ip
    );
}


=head2 console

Gives you a console in the container.

Note you can only grab ONE console. Really, 'enter' is the better command to be
using (although it doesn't work in maverick or earlier).

Takes a hash with the following keys:

=over 4

=item name

The name of the container to get a console in.

=back

=cut

sub console {
    my ($class, %args) = @_;
    my $name = $args{name} || die "Must specify what container to get a console in\n";
    $class->check_valid_container($name);

    die "Container '$name' is stopped\n" if $class->status(name => $name, brief => 1) eq 'stopped';

    my $lockfile = '/var/lib/lxc/' . $name . '/console-lock';

    die "You already have the console for this container open elsewhere\n" if -f $lockfile;
    write_file($lockfile, "locked by pid $$\n");

    system('lxc-console',
        '-n', $name,
    );

    unlink $lockfile;
}


=head2 status

Gives status information about one or all containers.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to get status information for (optional).

=item brief

Boolean, whether to output brief (machine readable) information (optional).

=back

=cut

sub status {
    my ($class, %args) = @_;

    if ( $args{name} ) {
        my $name = $args{name};
        $class->check_valid_container($name);

        if ( $args{brief} ) {
            my ($status, $stderr, $return_code) = tap('lxc-info', '-n', $name);
            if ( $status =~ m{^'\Q$name\E' is ([A-Z]+)$} ) {
                return lc $1;
            }
            die "Could not get status for container\n";
        }

        # TODO would be nice to provide more detail here
        system('lxc-info',
            '-n', $name
        );
        return;
    }

    # Status for all containers
    for my $dir (</var/lib/lxc/*>) {
        if ( -d $dir && $dir =~ m{/([^/]+)$} ) {
            system('lxc-info',
                '-n', $1,
            );
        }
    }
}


=head2 check_valid_container

Given a container name, checks if the name refers to an existing container.

=cut

sub check_valid_container {
    my ($class, $name) = @_;
    die "No such container '$name'\n" unless -d '/var/lib/lxc/' . $name;
}

=head1 AUTHOR

Shoptime Software

=cut

1;
