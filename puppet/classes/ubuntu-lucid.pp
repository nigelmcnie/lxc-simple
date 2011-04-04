# Ubuntu lucid configuration
class ubuntu-lucid {
    # Put your puppet configuration for your ubuntu lucid containers here
    $packages = [
        "less",
    ]
    package { $packages:
        ensure => "latest",
    }
}
