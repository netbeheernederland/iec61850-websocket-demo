#!/usr/bin/env bash
# Turn roles.env + nodes.env + the role templates into concrete per-node
# artifacts under build/<node>/:
#   user-data  meta-data  seed inputs   spec   compose.yaml
# plus build/certs/ (one CA + server/client cert whose SANs cover the fleet)
# and build/edge/: connections.json and the edge's Kea, BIND and Keycloak
# config, rendered from roles/edge/config/.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need envsubst; need base64; need docker; need md5sum

check_ssh_pubkey
mkdir -p "$BUILD_DIR"

###########################################################################
# 1. TLS material - regenerated only when the SAN set changes
###########################################################################
gen_certs() {
  local sans="localhost,127.0.0.1,${EDGE_IP},keycloak.${DNS_DOMAIN}" line n
  for line in "${NODES[@]}"; do
    read -r n _ <<<"$line"
    sans+=",${n},${n}.${MDNS_DOMAIN},${n}.${DNS_DOMAIN}"
  done
  local cdir="${BUILD_DIR}/certs"
  if [[ -f "${cdir}/.sans" && -f "${cdir}/ca.pem" \
        && "$(cat "${cdir}/.sans")" == "$sans" ]]; then
    log "certs up to date"
    return
  fi
  log "generating certs"
  log "  SANs: ${sans}"
  rm -rf "$cdir"; mkdir -p "$cdir"
  docker run --rm \
    -v "${CERTS_SRC}:/config:ro" -v "${cdir}:/out" -w /out \
    -e SANS="$sans" alpine:3.20 sh -eu -c '
      apk add --no-cache curl ca-certificates >/dev/null
      base="https://github.com/cloudflare/cfssl/releases/download/v1.6.5"
      curl -fsSL -o /usr/local/bin/cfssl     "$base/cfssl_1.6.5_linux_amd64"
      curl -fsSL -o /usr/local/bin/cfssljson "$base/cfssljson_1.6.5_linux_amd64"
      chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson
      cp /config/ca-config.json /config/ca-csr.json \
         /config/server-csr.json /config/client-csr.json /out/
      cfssl gencert -initca ca-csr.json | cfssljson -bare ca
      cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=server -hostname="$SANS" server-csr.json | cfssljson -bare server
      cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=client -hostname="$SANS" client-csr.json | cfssljson -bare client
      chmod 644 /out/*.pem
    '
  printf '%s' "$sans" > "${cdir}/.sans"
}
gen_certs

CA_PEM_B64="$(base64 -w0 < "${BUILD_DIR}/certs/ca.pem")"
SERVER_PEM_B64="$(base64 -w0 < "${BUILD_DIR}/certs/server.pem")"
SERVER_KEY_B64="$(base64 -w0 < "${BUILD_DIR}/certs/server-key.pem")"
CLIENT_PEM_B64="$(base64 -w0 < "${BUILD_DIR}/certs/client.pem")"
CLIENT_KEY_B64="$(base64 -w0 < "${BUILD_DIR}/certs/client-key.pem")"
export CA_PEM_B64 SERVER_PEM_B64 SERVER_KEY_B64 CLIENT_PEM_B64 CLIENT_KEY_B64

###########################################################################
# 2. edge-only artifacts: Kea + BIND + Keycloak config, connections.json
###########################################################################
EDGE_CONFIG_SRC="${SETUP_DIR}/roles/edge/config"

# TSIG secret shared by kea-dhcp-ddns and BIND; kept across renders.
ddns_tsig_secret() {
  local f="${BUILD_DIR}/edge/ddns-tsig.secret"
  if [[ ! -s "$f" ]]; then
    head -c 32 /dev/urandom | base64 > "$f"
    chmod 600 "$f"
  fi
  cat "$f"
}

render_edge_config() {
  local out="${BUILD_DIR}/edge" line n r ip sep=""
  mkdir -p "$out"

  EDGE_NAME=""
  KEA_RESERVATIONS=""
  for line in "${NODES[@]}"; do
    read -r n r ip _ <<<"$line"
    if [[ "$r" == "edge" ]]; then EDGE_NAME="$n"; continue; fi
    KEA_RESERVATIONS+="${sep}          { \"hw-address\": \"$(node_mac "$n")\", \"ip-address\": \"${ip}\", \"hostname\": \"${n}\" }"
    sep=$',\n'
  done
  [[ -n "$EDGE_NAME" ]] || die "nodes.env has no edge node"

  local a b c
  IFS=. read -r a b c <<<"$NET_PREFIX"
  REVERSE_ZONE="${c}.${b}.${a}.in-addr.arpa"
  EDGE_HOST_OCTET="${EDGE_IP##*.}"
  ZONE_SERIAL="$(date +%Y%m%d01)"
  DDNS_TSIG_SECRET="$(ddns_tsig_secret)"
  export EDGE_NAME KEA_RESERVATIONS REVERSE_ZONE EDGE_HOST_OCTET ZONE_SERIAL \
         DDNS_TSIG_SECRET DNS_DOMAIN EDGE_IP NET_GATEWAY NET_PREFIX \
         DHCP_RANGE_START DHCP_RANGE_END

  local vars='$DNS_DOMAIN $EDGE_NAME $EDGE_IP $EDGE_HOST_OCTET $NET_GATEWAY $NET_PREFIX
$DHCP_RANGE_START $DHCP_RANGE_END $KEA_RESERVATIONS $DDNS_TSIG_SECRET $REVERSE_ZONE $ZONE_SERIAL'
  local t
  for t in "${EDGE_CONFIG_SRC}"/*.tmpl; do
    envsubst "$vars" < "$t" > "${out}/$(basename "$t" .tmpl)"
  done
  rm -rf "${out}/keycloak"
  cp -r "${EDGE_CONFIG_SRC}/keycloak" "${out}/keycloak"
  log "rendered edge config (Kea, BIND for ${DNS_DOMAIN}, Keycloak realm)"
}

render_connections() {
  local out="${BUILD_DIR}/edge/connections.json" line n r ip
  local id=0 sep=""
  {
    echo "["
    for line in "${NODES[@]}"; do
      read -r n r ip NODE_EXTRA <<<"$line"
      local type acsi ws port
      case "$r" in
        so)  type="RTI-SO";  acsi="client"; ws="passive"; port=5000 ;;
        fsp) type="RTI-FSP"; acsi="server"; ws="active"
             port="$(extra port)"; port="${port:-5001}" ;;
        *)   continue ;;
      esac
      id=$((id + 1))
      printf '%s' "$sep"; sep=","
      cat <<JSON
  {
    "id": ${id},
    "name": "${n^^}",
    "host": "${n}.${MDNS_DOMAIN}",
    "port": ${port},
    "type": "${type}",
    "acsi": "${acsi}",
    "ws_mode": "${ws}",
    "auto_discovered": false,
    "OAuth": {
      "certificate_endpoint": "", "auth_server_ca": "", "realm": "",
      "token_endpoint": "", "client_id": "", "client_secret": "",
      "enable_token_refresh": false, "idp_server": ""
    },
    "status": "connected"
  }
JSON
    done
    printf '\n]\n'
  } > "$out"
  log "rendered edge/connections.json (${id} peers)"
}
render_edge_config
render_connections

b64() { base64 -w0 < "${BUILD_DIR}/edge/$1"; }
KEA_DHCP4_CONF_B64="$(b64 kea-dhcp4.conf)"
KEA_DDNS_CONF_B64="$(b64 kea-dhcp-ddns.conf)"
NAMED_OPTIONS_B64="$(b64 named.conf.options)"
NAMED_LOCAL_B64="$(b64 named.conf.local)"
ZONE_FWD_B64="$(b64 db.domain)"
ZONE_REV_B64="$(b64 db.reverse)"
KEYCLOAK_REALM_B64="$(b64 keycloak/iec61850-test-realm.json)"
CONNECTIONS_JSON_B64="$(b64 connections.json)"
export KEA_DHCP4_CONF_B64 KEA_DDNS_CONF_B64 NAMED_OPTIONS_B64 NAMED_LOCAL_B64 \
       ZONE_FWD_B64 ZONE_REV_B64 KEYCLOAK_REALM_B64 CONNECTIONS_JSON_B64

###########################################################################
# 3. per-node user-data / meta-data / spec / compose.yaml
###########################################################################
SUBST='$NODE_NAME $NODE_ROLE $NODE_IP $NODE_MAC $MDNS_DOMAIN $DNS_DOMAIN $VM_USER $SSH_PUBKEY
$EDGE_IP $NET_GATEWAY $NET_PREFIX $NET_NETMASK $DHCP_RANGE_START $DHCP_RANGE_END
$CA_PEM_B64 $SERVER_PEM_B64 $SERVER_KEY_B64 $CLIENT_PEM_B64 $CLIENT_KEY_B64
$FSP_CP $FSP_PORT $FSP_MODEL $FSP_MODELPATH $CONNECTIONS_JSON_B64
$KEA_DHCP4_CONF_B64 $KEA_DDNS_CONF_B64 $NAMED_OPTIONS_B64 $NAMED_LOCAL_B64
$ZONE_FWD_B64 $ZONE_REV_B64 $KEYCLOAK_REALM_B64 $REVERSE_ZONE'

render_node() {
  local d="${BUILD_DIR}/${NODE_NAME}" role="${NODE_ROLE}"
  local tdir="${SETUP_DIR}/roles/${role}"
  [[ -d "$tdir" ]] || die "unknown role '${role}' for node '${NODE_NAME}'"
  mkdir -p "$d"

  export NODE_NAME NODE_ROLE NODE_IP NODE_MAC \
         MDNS_DOMAIN VM_USER SSH_PUBKEY \
         EDGE_IP NET_GATEWAY NET_PREFIX NET_NETMASK DHCP_RANGE_START DHCP_RANGE_END
  export FSP_CP FSP_PORT FSP_MODEL FSP_MODELPATH
  FSP_CP="$(extra cp)"; FSP_PORT="$(extra port)"; FSP_MODEL="$(extra model)"
  FSP_MODELPATH=""; [[ -n "$FSP_MODEL" ]] && FSP_MODELPATH="/models/${FSP_MODEL}"

  printf 'VCPUS=%s\nRAM_MB=%s\nDISK=%s\nMAC=%s\nIP=%s\nROLE=%s\n' \
    "$(role_field "$role" 0)" "$(role_field "$role" 1)" "$(role_field "$role" 2)" \
    "$NODE_MAC" "$NODE_IP" "$role" > "$d/spec"

  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NODE_NAME" "$NODE_NAME" > "$d/meta-data"

  envsubst "$SUBST" < "${tdir}/cloud-init.yaml.tmpl" > "$d/user-data"

  if [[ -f "${tdir}/compose.yaml.tmpl" ]]; then
    envsubst "$SUBST" < "${tdir}/compose.yaml.tmpl" > "$d/compose.yaml"
  else
    cp "${tdir}/compose.yaml" "$d/compose.yaml"
  fi
  log "rendered ${NODE_NAME} (${role})"
}
for_each_node render_node

log "done -> ${BUILD_DIR}"
