# == Define: ssl::cert
#
# Setups up the necessary components for an SSL certificate, including
# the private key, self-signed (temporary cert) and CSR. If any names are
# provided for the alt_names parameter, a SAN (Subject Alternative Name)
# request will be generated.
#
# === Parameters:
# [*cn*]
#   Primary common name.  Defaults to the name of the resource.
#
# [*country*]
#   2-letter country code
#
# [*state*]
#   State name
#
# [*city*]
#   City name
#
# [*org*]
#   Organization Name
#
# [*org_unit*]
#   Organization Unit Name
#
# [*alt_names*]
#   Array of alternate DNS names
#
# === Author:
#   Aaron Russo <arusso@berkeley.edu>
define ssl::cert(
  $cn = $name,
  $country = params_lookup( 'country', false ),
  $state = params_lookup( 'state', false ),
  $city = params_lookup( 'city', false ),
  $org = params_lookup( 'org', false),
  $org_unit = params_lookup( 'org_unit', false),
  $alt_names = params_lookup( 'alt_names', false)
) {
  include ssl
  include ssl::params
  include ssl::package

  $hostname_regex = '^(?i:)(((([a-z0-9][-a-z0-9]{0,61})?[a-z0-9])[.])*([a-z][-a-z0-9]{0,61}[a-z0-9]|[a-z])[.]?)$'

  validate_re( $country, '^[A-Z]{2}$' )
  validate_re( $state, '^(?i)[A-Z]+$' )
  validate_re( $city, '^(?i)[A-Z ]+$' )
  validate_string( $org )
  validate_string( $org_unit )
  validate_re( $cn, $hostname_regex,
          "ssl:cert resource '${cn}' does not appear to be a valid hostname." )
  validate_array( $alt_names )

  # Add our CN to the alt_names list
  $alt_names_real = flatten( unique( [ $cn, $alt_names ] ) )

  $cnf_file = "${ssl::params::crt_dir}/meta/${cn}.cnf"
  $key_file = "${ssl::params::key_dir}/${cn}.key"
  $crt_file = "${ssl::params::crt_dir}/${cn}.crt"
  $pem_file = "${ssl::params::pem_dir}/${cn}.pem"
  $csr_file = "${ssl::params::crt_dir}/meta/${cn}.csr"
  $csrh_file = "${ssl::params::crt_dir}/meta/${cn}.csrh"

  # Generate our Key file
  # this should only happen once, evar!
  exec { "generate-key-${cn}":
    command => "/usr/bin/openssl genrsa -out ${key_file} 2048",
    creates => $key_file,
    path    => [ '/bin', '/usr/bin' ],
    require => [ Class['ssl::package'], File["${ssl::params::crt_dir}/meta"] ]
  }

  # Enforce permissions on the private key so it isn't readable by anyone
  # but root
  file { $key_file:
    ensure  => present,
    mode    => '0600',
    owner   => 'root',
    group   => 'root',
    require => Exec["generate-key-${cn}"],
  }

  # Generate our config file
  # This can change as we change SAN names and the whatnot. This should trigger
  # the re-generation of a CSR, CSRH but NOT the CRT or the KEY since we dont
  # want it overwriting a legit cert or key.  We'll let the installation classes
  # handle updating the certs
  file { $cnf_file:
    ensure  => 'file',
    owner   => 'root',
    group   => 'root',
    mode    => '0440',
    content => template('ssl/host.cnf.erb'),
    before  => Exec["generate-key-${cn}"],
    notify  => Exec["generate-csr-${cn}"],
  }

  # Generate our CSR.  Once this is done, kick off the CSRH regeneration
  exec { "generate-csr-${cn}":
    refreshonly => true,
    command     => "/usr/bin/openssl req -config ${cnf_file} -new -nodes \
                     -key ${key_file} -out ${csr_file}",
    path        => [ '/bin', '/usr/bin' ],
    require     => Exec["generate-key-${cn}"],
    notify      =>  Exec["generate-csrh-${cn}"],
  }

  # Generate our Self Signed Cert
  exec { "generate-self-${cn}":
    creates     => $crt_file,
    command     => "/usr/bin/openssl req -config ${cnf_file} -new -nodes \
                     -key ${key_file} -out ${crt_file} -x509",
    path    => [ '/bin', '/usr/bin' ],
    notify  => Exec["generate-combined-${cn}"],
    require => Exec["generate-key-${cn}"],
  }

  # Generate combined PEM file
  exec { "generate-combined-${cn}":
    command => "cat ${key_file} ${crt_file} > ${pem_file}",
    creates => $pem_file,
    path    => [ '/bin', '/usr/bin' ],
    require => [Exec["generate-self-${cn}"], File[$key_file]],
  }

  file { $pem_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Exec["generate-combined-${cn}"]
  }

  exec { "generate-csrh-${cn}":
    refreshonly => true,
    command     => "/usr/bin/openssl req -in ${csr_file} -text > ${csrh_file}",
    path        => [ '/bin', '/usr/bin' ],
    require     => Exec["generate-csr-${cn}"],
  }
}
