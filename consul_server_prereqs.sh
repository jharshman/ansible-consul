#!/usr/bin/env bash

usage() {
  cat <<EOM
Usage: $0 [options]

Options:
  --domain | -d    Set Domain.
  --help   | -h    Display usage.
EOM
}

main() {

  local _domain

  while (( $# )); do
    case "$1" in
      --domain|-d)
        _domain=$2
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage
        exit 0
        ;;
    esac
  done

  if [[ -z $_domain ]]; then
    usage
    exit 1
  fi

  # create ca
  $CONSUL_BIN tls ca create \
    -domain="$_domain"      \
    ;

  # create server certificates
  $CONSUL_BIN tls cert create -server \
    -ca="$_domain-agent-ca.pem"       \
    -key="$_domain-agent-ca-key.pem"  \
    -domain="$_domain"                \
    ;

  # create gossip key and initial management token
  # store in file and as var
  gossip_key=$($CONSUL_BIN keygen)
  init_mgmt_token=$(cat /proc/sys/kernel/random/uuid)
  echo $gossip_key > gossip.key
  cat << EOM > roles/server/vars/generated.yml
consul_gossip_key: $gossip_key
consul_init_mgmt_token: $init_mgmt_token
EOM

  # move to roles/server/files/secrets/
  mkdir -p roles/server/files/secrets
  mv $_domain-agent-ca.pem roles/server/files/secrets/ca.pem
  mv $_domain-agent-ca-key.pem roles/server/files/secrets/ca-key.pem
  mv dc1-server-$_domain-0.pem roles/server/files/secrets/server-cert.pem
  mv dc1-server-$_domain-0-key.pem roles/server/files/secrets/server-cert-key.pem
  mv gossip.key roles/server/files/secrets/

  # encrypt with ansible-vault and randomly generated password
  randPass=$(pwgen 10 1)
  echo $randPass > password_file.txt
  echo -n "encrypting tls certs and keys... "
  ansible-vault encrypt --vault-password-file password_file.txt roles/server/files/secrets/*
  echo -n "encrypting gossip key... "
  ansible-vault encrypt --vault-password-file password_file.txt roles/server/vars/generated.yml

  # ensure that "password_file" is in .gitignore
  if [[ ! -f .gitignore ]]; then
    # create a .gitignore
    echo "password_file.txt" > .gitignore
  elif ! grep -q 'password_file.txt' .gitignore; then
    # append to .gitignore
    echo "password_file.txt" >> .gitignore
  fi

  cat <<EOM

-----------------------------------------------------------
Run the following command to install and configure Consul.

  ansible-playbook -e @roles/server/vars/generated.yml --vault-password-file password_file.txt -i all.ini playbook.yml

-----------------------------------------------------------

To access Consul through the CLI, run the following in your terminal session.

  ansible-vault view --vault-password-file password_file.txt roles/server/files/secrets/ca.pem > ~/consul_ca.pem
  export CONSUL_HTTP_ADDR=https://server.dc1.$_domain:8501
  export CONSUL_HTTP_SSL=true
  export CONSUL_CACERT=~/consul_ca.pem 
  export CONSUL_TLS_SERVER_NAME=server.dc1.$_domain
  export CONSUL_FQDN_ADDR=harshman.me
  export CONSUL_HTTP_TOKEN=$init_mgmt_token
EOM

}

install_consul() {
  mkdir -p ~/.local/bin/
  case "$(uname -m)" in
  x86_64)
    wget -q -o https://releases.hashicorp.com/consul/1.15.2/consul_1.15.2_linux_amd64.zip/tmp/consul.zip
    ;;
  esac
  unzip -d ~/.local/consul /tmp/consul.zip
}

CONSUL_BIN=$(which consul)
if [[ $CONSUL_BIN == "" ]]; then
  install_consul
  CONSUL_BIN=$HOME/.local/bin/consul
fi
main "$@"

