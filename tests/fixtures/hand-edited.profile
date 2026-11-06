# AppArmor profile for myapp
include <tunables/global>

profile myapp flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/openssl>

  # A human decided this service must never read the serviceaccount token.
  deny "/var/run/secrets/kubernetes.io/**" r,
  deny /etc/shadow rwklx,

  capability chown,
  network inet stream,

  owner /var/lib/myapp/** rw,
  audit /etc/myapp/secret.key r,

  "/etc/myapp/config.yaml" r,

  profile myapp//helper {
    include <abstractions/base>
    /usr/bin/helper rix,
  }
}
