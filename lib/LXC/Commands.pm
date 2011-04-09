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
use Moose;

use File::Slurp;
use Passwd::Unix;
use Sysadm::Install qw(tap);
use Time::HiRes qw(usleep);

=head1 NAME

LXC::Commands - commands for LXC

=head1 DESCRIPTION

Contains routines that back the LXC commands. Normally, you would access these
through the 'lxc' script, but you can include this module and use them directly
if you wish.

=head1 METHODS

=cut


has lxc_dir => (
    is => 'rw',
    isa => 'Path::Class::Dir',
    required => 1,
);

has puppet_dir => (
    is => 'rw',
    isa => 'Path::Class::Dir',
    required => 1,
);


=head2 create

Creates a new container.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to create.

=item autostart

Whether the container should be flagged to be automatically started on boot.

=item install_user

If true, bind mounts /home into the container. Also, if this script was invoked
by C<sudo>, it creates an account and group in the container for that user,
using the same details as on the host (e.g. same password).

=item mirror

The mirror to use to download packages.

=item start

Whether to start the container once created.

=item template

The template to use to create the container (see C<lxc-create>'s C<--template>
option).

=back

=cut

sub create {
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify a name for the container to be created\n";

    system('lxc-create',
        '-n', $name,                    # TODO: check for invalid name first?
        '-f', '/etc/lxc/lxc.conf',      # TODO: this is for networking stuff
        '-t', $args{template} // 'ubuntu',
    ) == 0
        or die "lxc-create failed with exit code $?\n";

    my $container_cfgroot = $self->lxc_dir->subdir($name);
    my $container_root    = $self->lxc_dir->subdir($name . '/rootfs/');
    my $puppet_root       = $self->puppet_dir;

    # Puppet mount
    mkdir($container_root->subdir('etc/lxc-puppet'));
    append_file($container_cfgroot->file('fstab')->stringify,
        sprintf("$puppet_root    %s    auto bind 0 0\n", $container_root . '/etc/lxc-puppet'));

    # Dump autostart file down if asked for
    write_file($container_cfgroot->file('autostart')->stringify, '') if $args{autostart};

    # Install our own /etc/network/interfaces
    my $interfaces_content = q(
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    # NOTE: if you're making your own interface definition, leave this line in
    # place so that 'lxc [name] enter' will work
    up ip a s dev eth0 | grep 'inet\W' | awk '{print $2}' | cut -f 1 -d '/' > /lxc-ip
    down rm /lxc-ip
);
    write_file($container_root->file('etc/network/interfaces')->stringify, $interfaces_content);

    # Bindmount homedir and install user account if asked for
    if ( $args{install_user} ) {
        # TODO naturally, we could grab this information from a config file
        if ( exists $ENV{SUDO_USER} ) {
            my $user  = $ENV{SUDO_USER};
            my $group = $ENV{SUDO_USER};

            mkdir "$container_root/home/$user";
            append_file($container_cfgroot->file('fstab')->stringify,
                sprintf("/home/$user           %s         auto bind 0 0\n", "$container_root/home/$user"));

            my $hostpw = Passwd::Unix->new(
                passwd => '/etc/passwd',
                shadow => '/etc/shadow',
                group  => '/etc/group',
                backup => 0,
            );
            my @userinfo  = $hostpw->user($user);
            my @groupinfo = $hostpw->group($group);

            my $containerpw = Passwd::Unix->new(
                passwd => $container_root->file('etc/passwd'),
                shadow => $container_root->file('etc/shadow'),
                group  => $container_root->file('etc/group'),
                backup => 0,
            );
            $containerpw->user($user, @userinfo);
            $containerpw->group($group, @groupinfo);
        }
        else {
            print "Could not establish what user to install, skipping\n";
        }
    }

    # Start the container so we can run initial commands inside it
    $self->start(name => $name);

    if ( $args{mirror} ) {
        my $mirror = $args{mirror};
        my $apt_sources_file = $container_root->file('etc/apt/sources.list')->stringify;

        my $contents = read_file($apt_sources_file);
        $contents =~ s/archive.ubuntu.com/$mirror/g;
        write_file($apt_sources_file, $contents);

        $self->enter(
            name    => $name,
            command => [ qw(apt-get update) ],
        );
    }

    # Install gpgv so we can validate apt repos, then do an apt update
    $self->enter(
        name    => $name,
        command => [ qw(apt-get install -y --force-yes gpgv) ],
    );
    $self->enter(
        name    => $name,
        command => [ qw(apt-get update) ],
    );

    # Install puppet in the container
    # NOTE: installing policycoreutils to somewhat shut puppet up on lucid
    $self->enter(
        name    => $name,
        command => [ qw(apt-get -y --no-install-recommends install puppet policycoreutils) ],
    );

    # Write a node definition for this container
    write_file($puppet_root->file("nodes/$name.pp")->stringify, qq(# Puppet node definition for $name
node "$name" {
    include ubuntu-lucid
}
));
    # Run puppet in the container for the first time
    $self->enter(
        name    => $name,
        command => [ qw(puppet /etc/lxc-puppet/site.pp) ],
    );

    $self->stop(name => $name) unless $args{start};
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
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to destroy\n";
    $self->check_valid_container($name);

    if ( $self->status(name => $name, brief => 1) eq 'running' ) {
        $self->stop(name => $name);
    }

    print "Destroying $name... ";
    my $puppet_file = $self->puppet_dir->file("nodes/$name.pp");
    if ( -f $puppet_file ) {
        system('mv', $puppet_file, $puppet_file . '.old');
    }
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
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to start\n";
    $self->check_valid_container($name);

    die "Container '$name' IS started\n" if $self->status(name => $name, brief => 1) eq 'running';

    print "Starting $name... ";
    system('lxc-start',
        '-n', $name,
        '-d',
    );
    system('lxc-wait',
        '-n', $name,
        '-s', 'RUNNING',
    );

    # NOTE: this will go away once Martyn works out a smarter way of handling
    # container networking
    for (1..100) {
        last if -f $self->lxc_dir->file("$name/rootfs/lxc-ip");
        if ( $_ == 100 ) {
            print "Could not confirm container started, check with 'lxc $name enter'\n";
            return;
        }
        usleep 100_000;
    }

    print "done\n";
}


=head2 stop

Gracefully stops a container.

This runs 'halt' in the container and then waits until all processes have
exited, or some time has passed. If processes are still around after that time,
it murders them.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to stop.

=back

=cut

sub stop {
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to stop\n";
    $self->check_valid_container($name);

    die "Container '$name' IS stopped\n" if $self->status(name => $name, brief => 1) eq 'stopped';

    print "Stopping $name... ";

    $self->enter(
        name    => $name,
        command => [ qw(halt) ],
    );
    unlink $self->lxc_dir->file("$name/rootfs/lxc-ip");

    # Now we wait until all the processes go away
    my $timeout = 20;
    my $unresponsive = 1;
    for (1..$timeout*10) {
        my ($stdout, $stderr, $return_code) = tap(
            'lxc-ps',
            '--lxc',
            'ax',
        );
        print STDERR $stderr;
        exit $return_code if $return_code;

        my $count = grep { $_ =~ /^\Q$name\E/ } split "\n", $stdout;
        unless ( $count ) {
            $unresponsive = 0;
            last;
        }

        usleep 100_000;
    }

    if ( $unresponsive ) {
        print "WARNING: Container '$name' still wasn't shut down after $timeout seconds, forcing it... ";
        system('lxc-stop',
            '-n', $name,
        );
        system('lxc-wait',
            '-n', $name,
            '-s', 'STOPPED',
        );
    }

    print "done\n";
}


=head2 restart

Restarts a container.

This issues a stop, if the container is running, and then a start. After this,
the container will be running even if it wasn't before.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to restart.

=back

=cut

sub restart {
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to restart\n";
    $self->check_valid_container($name);

    if ( $self->status(name => $name, brief => 1) eq 'stopped' ) {
        print "Container '$name' already stopped\n";
    }
    else {
        $self->stop(name => $name);
    }

    $self->start(name => $name);
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

=item command

An arrayref containing a command and arguments to run in the container
(optional).

=back

=cut

sub enter {
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to get a shell in\n";
    $self->check_valid_container($name);
    $args{command} //= [];

    die "Container '$name' is stopped\n" if $self->status(name => $name, brief => 1) eq 'stopped';

    my $ip_file = $self->lxc_dir->file("$name/rootfs/lxc-ip")->stringify;
    die "Could not determine IP to ssh to (maybe networking isn't up in '$name' yet)\n" unless -f $ip_file;
    my $ip = read_file($ip_file);
    chomp $ip;
    die "No IP available for container '$name'" unless $ip;
    die "Could not determine IP to ssh to" unless $ip =~ m{^\d+\.\d+\.\d+\.\d+$};

    my $host_key = read_file($self->lxc_dir->file("$name/rootfs/etc/ssh/ssh_host_rsa_key.pub")->stringify);
    $host_key = (split /\s+/, $host_key)[1];

    # Generate an ssh keypair unless one already exists
    my $ssh_key_file = $self->lxc_dir->file("$name/ssh.key");
    unless ( -f $ssh_key_file ) {
        my ($stdout, $stderr, $return_code) = tap(
            'ssh-keygen',
            '-f' => $ssh_key_file,
            '-P' => '',
        );
        print STDERR $stderr;
        exit $return_code if $return_code;
    }

    # Write out a known hosts file based on the ssh host key of the guest
    write_file($self->lxc_dir->file("$name/ssh.known_hosts")->stringify, "$ip ssh-rsa $host_key\n");

    # Ensure root has the appropriate authorized_keys file in place
    system('mkdir', '-p', $self->lxc_dir->file("$name/rootfs/root/.ssh"));
    system('cp', $self->lxc_dir->file("$name/ssh.key.pub"), $self->lxc_dir->file("$name/rootfs/root/.ssh/authorized_keys"));

    system('ssh',
        '-l' => 'root',
        '-i' => $self->lxc_dir->file("$name/ssh.key"),
        '-o' => 'UserKnownHostsFile=' . $self->lxc_dir->file("$name/ssh.known_hosts"),
        $ip,
        @{$args{command}}
    );
}


=head2 console

Gives you a console in the container.

Note you can only grab ONE console. Really, 'enter' is the better command to be
using, but if networking is down in the container, you'll have to use this.

Takes a hash with the following keys:

=over 4

=item name

The name of the container to get a console in.

=back

=cut

sub console {
    my ($self, %args) = @_;
    my $name = $args{name} || die "Must specify what container to get a console in\n";
    $self->check_valid_container($name);

    die "Container '$name' is stopped\n" if $self->status(name => $name, brief => 1) eq 'stopped';

    my $lockfile = $self->lxc_dir->file("$name/console-lock")->stringify;

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
    my ($self, %args) = @_;

    if ( $args{name} ) {
        my $name = $args{name};
        $self->check_valid_container($name);

        if ( $args{brief} ) {
            my ($status, $stderr, $return_code) = tap('lxc-info', '-n', $name);
            if ( $status =~ m{^'\Q$name\E' is ([A-Z]+)$} ) {
                return lc $1;
            }
            print STDERR $stderr;
            die "Could not get status for container\n";
        }

        # TODO would be nice to provide more detail here
        system('lxc-info',
            '-n', $name
        );
        return;
    }

    # Status for all containers
    my $lxc_dir = $self->lxc_dir;
    for my $dir (<$lxc_dir/*>) {
        if ( -d $dir && $dir =~ m{/([^/]+)$} ) {
            system('lxc-info',
                '-n', $1,
            );
        }
    }
}


=head2 resync

Runs puppet in container(s).

Takes a hash with the following keys:

=over 4

=item name

The name of the container to get status information for (optional).

=item all

Boolean, whether to run puppet in B<all> containers, even stopped ones. This
will start them to run puppet, and stop them once done.

=back

=cut

sub resync {
    my ($self, %args) = @_;

    if ( $args{name} ) {
        my $name = $args{name};
        $self->check_valid_container($name);

        $self->enter(
            name    => $name,
            command => [ qw(puppet /etc/lxc-puppet/site.pp) ],
        );
        return;
    }

    # Resync all - basic "one at a time" method, would be nicer to do them in
    # parallel
    my $lxc_dir = $self->lxc_dir;
    for my $dir (<$lxc_dir/*>) {
        if ( -d $dir && $dir =~ m{/([^/]+)$} ) {
            my $name = $1;
            my $was_stopped = 0;

            if ( $self->status(name => $name, brief => 1) eq 'stopped' ) {
                if ( $args{all} ) {
                    $self->start(name => $name);
                    $was_stopped = 1;
                }
                else {
                    next;
                }
            }

            eval {
                $self->enter(
                    name    => $name,
                    command => [ qw(puppet /etc/lxc-puppet/site.pp) ],
                );
            };
            print STDERR $@ if $@;

            if ( $was_stopped ) {
                $self->stop(name => $name);
            }
        }
    }
}


=head2 autostart

Starts all containers that have a file called 'autostart' in their lxc config
directory.

=cut

sub autostart {
    my ($self, %args) = @_;

    my $lxc_dir = $self->lxc_dir;
    for my $dir (<$lxc_dir/*>) {
        if ( -d $dir && $dir =~ m{/([^/]+)$} && -f "$dir/autostart" ) {
            # Try to start, but don't bail out if it's not possible
            eval {
                $self->start(name => $1);
            };
            print STDERR $@ if $@;
        }
    }
}


=head2 stopall

Stops all containers.

=cut

sub stopall {
    my ($self, %args) = @_;

    my $lxc_dir = $self->lxc_dir;
    for my $dir (<$lxc_dir/*>) {
        if ( -d $dir && $dir =~ m{/([^/]+)$} ) {
            # Try to stop, but don't bail out if we couldn't stop one
            eval {
                $self->stop(name => $1) if $self->status(name => $1, brief => 1) eq 'running';
            };
            print STDERR $@ if $@;
        }
    }
}


=head2 check_valid_container

Given a container name, checks if the name refers to an existing container.

=cut

sub check_valid_container {
    my ($self, $name) = @_;
    die "No such container '$name'\n" unless -d $self->lxc_dir->subdir($name);
}


=head1 AUTHOR

Shoptime Software

=cut

1;
