Getting started with lxc
========================

1. Install dependencies
-----------------------

    apt-get install lxc debootstrap libpasswd-unix-perl libfile-slurp-perl \
                    libmoose-perl libpath-class-perl libconfig-inifiles-perl

2. Set up networking
--------------------

Your containers need a way to talk to the interweb. One way is a bridge.

A bridge is basically like a switch. You can plug your ``eth0`` into it, and
also each container. Then they can all talk to each other and the outside
world.

Put something like this in ``/etc/network/interfaces``:

    auto lo
    iface lo inet loopback

    iface eth0 inet manual

    auto br0
    iface br0 inet dhcp
        bridge_ports eth0
        bridge_stp off
        post-up /usr/sbin/brctl setfd br0 0

If you have a static lease, configure br0 with that information instead of the
dhcp line::

    iface br0 inet static
        address [your ip]
        netmask [your netmask]
        broadcast [your broadcast]
        gateway [your gateway]
        bridge_ports eth0
        bridge_stp off
        post-up /usr/sbin/brctl setfd br0 0

3. Put info about networking setup in a file for later use
----------------------------------------------------------

When containers are created, we need to tell them how to access the network.
Put this in ``/etc/lxc/lxc.conf``:

    lxc.network.type=veth
    lxc.network.link=br0
    lxc.network.flags=up

4. You're ready!
----------------

    # Summary of commands
    lxc --help

    # Create a container called 'test'
    lxc test create

    # Start the container
    lxc test start

    # Enter it
    lxc test enter

    # Stop the container
    lxc test stop

    # Destroy it (you'll be asked to confirm)
    lxc test destroy

5. Starting containers automatically on boot
--------------------------------------------

On ubuntu, install the upstart jobs:

    cp upstart/lxc-* /etc/init

And when you create your containers, use -a to flag them as ones that should be
automatically started on boot.

If you have a container you already made that you want to start on boot:

    touch /var/lib/lxc/[name]/autostart

Good luck!
 -- Nigel McNie & Martyn Smith
