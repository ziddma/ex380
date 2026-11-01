#!/usr/bin/env bash
set -Eeuo pipefail

# Composite EX380 mock preparation for the Red Hat DO380 classroom.
# Version 11: run auth-ldap, validate it, finish it, then start compreview-review.
# Every lab command runs from HOME. compreview-review remains active for the mock.
#
# It preserves the Loki S3 credentials supplied by the lab, but deletes the
# OADP OBC named "backup" so that the candidate must create it themselves.

LAB_NAME="compreview-review"
LDAP_LAB_NAME="auth-ldap"
LDAP_LAB_DIR="$HOME/DO380/labs/$LDAP_LAB_NAME"
API_URL="https://api.lab.example.com:6443"
ADMIN_USER="admin"
ADMIN_PASSWORD="redhatocp"
LAB_DIR="$HOME/DO380/labs/$LAB_NAME"
MOCK_HOME="$HOME/ex380-mock"
ASSET_DIR="$MOCK_HOME/assets"
MATERIAL_DIR="$MOCK_HOME/materials"
STATE_DIR="$MOCK_HOME/preparation-state"
LOKI_ENV_SOURCE="$LAB_DIR/s3bucket.env"
LOKI_ENV_SAVED="$ASSET_DIR/loki-s3.env"
EVENTROUTER_IMAGE="${EVENTROUTER_IMAGE:-registry.lab.example.com:8443/openshift-logging/eventrouter-rhel9:v0.4}"
RHDS_CA_URL="${RHDS_CA_URL:-https://raw.githubusercontent.com/ziddma/ex380/main/rhds_ca.crt}"
RHDS_CA_FILE="$ASSET_DIR/rhds_ca.crt"
RHDS_CA_EXPECTED_SHA256="50045fdb01427adefe177ebd605876e654888aad13fde8166af314cd4555ff37"
RHDS_HOST="rhds.lab.example.com"
RHDS_PORT="636"
RHDS_BIND_DN="cn=Directory Manager"
RHDS_BIND_PASSWORD="redhatocp"
RHDS_USER_DN="uid=kristendelgado,ou=people,dc=example,dc=com"
RHDS_USER_PASSWORD="redhat123"
RHDS_GROUP_DN="cn=administrators,ou=people,dc=example,dc=com"
RHDS_LAB_CA_FILE="$ASSET_DIR/rhds-ca-auth-ldap.crt"
CURRENT_STAGE="initialization"

log() {
  CURRENT_STAGE="$*"
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

trap 'rc=$?; printf "\nERROR: stage [%s] failed at line %s (exit %s). Preparation incomplete.\n" "$CURRENT_STAGE" "$LINENO" "$rc" >&2; exit "$rc"' ERR

run_lab() {
  local action="$1"
  local exercise="$2"
  local rc

  log "Running: lab $action $exercise (from $HOME)"
  # A blocking call: validation and the next lab run only after this finishes.
  if (cd "$HOME" && lab "$action" "$exercise"); then
    printf 'PASS: lab %s %s finished with exit code 0.\n' "$action" "$exercise"
  else
    rc=$?
    printf 'STOP: lab %s %s failed (exit %s). No next stage was started.\n' \
      "$action" "$exercise" "$rc" >&2
    return "$rc"
  fi
}

check_admin_session() {
  log "Checking the OpenShift administrator session"
  if oc whoami >/dev/null 2>&1 && \
     [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" == "yes" ]]; then
    printf 'Using the existing cluster-admin session: %s\n' "$(oc whoami)"
  else
    oc login -u "$ADMIN_USER" -p "$ADMIN_PASSWORD" "$API_URL"
  fi

  if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]]; then
    printf 'STOP: The current session does not have cluster-admin access.\n' >&2
    return 1
  fi
}

verify_rhds_data() {
  local stage="$1"
  local user_file="$STATE_DIR/ldap-${stage}-user.ldif"
  local group_file="$STATE_DIR/ldap-${stage}-group.ldif"
  local bind_file="$STATE_DIR/ldap-${stage}-user-bind.txt"

  log "Validating RHDS data and user credentials: $stage"
  LDAPTLS_CACERT="$RHDS_CA_FILE" LDAPTLS_REQCERT=demand \
    ldapsearch -x -LLL -o ldif-wrap=no -o nettimeout=15 -l 20 \
      -D "$RHDS_BIND_DN" -w "$RHDS_BIND_PASSWORD" \
      -H "ldaps://$RHDS_HOST:$RHDS_PORT" \
      -b "ou=people,dc=example,dc=com" \
      '(uid=kristendelgado)' dn uid cn memberOf > "$user_file"

  LDAPTLS_CACERT="$RHDS_CA_FILE" LDAPTLS_REQCERT=demand \
    ldapsearch -x -LLL -o ldif-wrap=no -o nettimeout=15 -l 20 \
      -D "$RHDS_BIND_DN" -w "$RHDS_BIND_PASSWORD" \
      -H "ldaps://$RHDS_HOST:$RHDS_PORT" \
      -b "ou=people,dc=example,dc=com" \
      '(cn=administrators)' dn cn uniqueMember > "$group_file"

  if ! grep -Fxq "dn: $RHDS_USER_DN" "$user_file" || \
     ! grep -Fxq 'uid: kristendelgado' "$user_file" || \
     ! grep -Fxq "memberOf: $RHDS_GROUP_DN" "$user_file" || \
     ! grep -Fxq "dn: $RHDS_GROUP_DN" "$group_file" || \
     ! grep -Fxq "uniqueMember: $RHDS_USER_DN" "$group_file"; then
    printf 'STOP: RHDS user/group/membership validation failed after %s.\n' "$stage" >&2
    printf 'Inspect %s and %s. No LDAP entries were created or modified.\n' \
      "$user_file" "$group_file" >&2
    return 1
  fi

  LDAPTLS_CACERT="$RHDS_CA_FILE" LDAPTLS_REQCERT=demand \
    ldapwhoami -x -o nettimeout=15 \
      -H "ldaps://$RHDS_HOST:$RHDS_PORT" \
      -D "$RHDS_USER_DN" -w "$RHDS_USER_PASSWORD" > "$bind_file"
  if ! grep -Fxq "dn:$RHDS_USER_DN" "$bind_file"; then
    printf 'STOP: User bind did not return the expected kristendelgado DN.\n' >&2
    return 1
  fi

  printf 'PASS: kristendelgado, administrators, both membership attributes, and user bind.\n'
}

verify_compreview_materials() {
  local relative_path

  log "Validating compreview-review materials and Etherpad"
  for relative_path in \
    s3bucket.env schedule-db-backup.yaml sso_config.yaml \
    logging/lokistack.yaml logging/forwarder.yaml \
    logging/uiplugin.yaml logging/group-role.yaml; do
    if [[ ! -s "$LAB_DIR/$relative_path" ]]; then
      printf 'STOP: Required lab material is missing or empty: %s\n' \
        "$LAB_DIR/$relative_path" >&2
      return 1
    fi
  done

  # Check required fields without printing access or secret keys.
  if ! bash -c '
    source "$1"
    [[ -n "${bucketnames:-}" && -n "${endpoint:-}" &&
       -n "${access_key_id:-}" && -n "${access_key_secret:-}" ]]
  ' _ "$LOKI_ENV_SOURCE"; then
    printf 'STOP: s3bucket.env must contain bucketnames, endpoint, access_key_id, and access_key_secret.\n' >&2
    return 1
  fi

  oc get namespace "$LAB_NAME"
  oc get deployment etherpad -n "$LAB_NAME"
  oc rollout status deployment/etherpad -n "$LAB_NAME" --timeout=300s
  oc get route etherpad -n "$LAB_NAME"
  printf 'PASS: required lab files, Loki credential fields, and Etherpad rollout.\n'
}

download_rhds_ca() {
  local temporary_file
  local actual_sha256

  temporary_file="$(mktemp "$ASSET_DIR/.rhds_ca.crt.XXXXXX")"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error \
      --retry 3 --connect-timeout 15 \
      "$RHDS_CA_URL" -o "$temporary_file"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet --tries=3 --timeout=15 \
      -O "$temporary_file" "$RHDS_CA_URL"
  else
    printf 'curl or wget is required to download the RHDS CA.\n' >&2
    rm -f "$temporary_file"
    return 1
  fi

  if ! openssl x509 -in "$temporary_file" -noout >/dev/null 2>&1; then
    printf 'The downloaded RHDS CA is not a valid PEM certificate: %s\n' \
      "$RHDS_CA_URL" >&2
    rm -f "$temporary_file"
    return 1
  fi

  actual_sha256="$(openssl x509 -in "$temporary_file" -outform DER \
    | sha256sum | awk '{print $1}')"

  if [[ "$actual_sha256" != "$RHDS_CA_EXPECTED_SHA256" ]]; then
    printf 'RHDS CA fingerprint mismatch.\nExpected: %s\nReceived: %s\n' \
      "$RHDS_CA_EXPECTED_SHA256" "$actual_sha256" >&2
    rm -f "$temporary_file"
    return 1
  fi

  install -m 0644 "$temporary_file" "$RHDS_CA_FILE"
  rm -f "$temporary_file"

  printf 'RHDS CA downloaded from: %s\n' "$RHDS_CA_URL"
  openssl x509 -in "$RHDS_CA_FILE" \
    -noout -subject -issuer -dates -fingerprint -sha256
}

verify_rhds_tls() {
  local output_file

  if ! getent hosts "$RHDS_HOST" > "$STATE_DIR/rhds-dns.txt"; then
    printf '%s cannot be resolved. LDAP Task 1 is not ready.\n' \
      "$RHDS_HOST" >&2
    return 1
  fi

  output_file="$STATE_DIR/rhds-tls-verification.txt"
  if ! timeout 20 openssl s_client \
      -connect "${RHDS_HOST}:${RHDS_PORT}" \
      -servername "$RHDS_HOST" \
      -CAfile "$RHDS_CA_FILE" \
      -verify_return_error </dev/null > "$output_file" 2>&1; then
    cat "$output_file" >&2
    printf 'The downloaded CA cannot verify %s:%s.\n' \
      "$RHDS_HOST" "$RHDS_PORT" >&2
    return 1
  fi

  if ! grep -Fq 'Verify return code: 0 (ok)' "$output_file"; then
    cat "$output_file" >&2
    printf 'RHDS TLS verification did not return code 0.\n' >&2
    return 1
  fi

  grep -F 'Verify return code:' "$output_file"
}

has_resource() {
  # Do not use grep -q here. With pipefail enabled, grep can close the pipe
  # early and make `oc api-resources` return SIGPIPE, producing a false result.
  oc api-resources -o name 2>/dev/null | grep -Fx "$1" >/dev/null
}

delete_crb_for_subject() {
  local subject_kind="$1"
  local subject_name="$2"
  local subject_namespace="${3:-}"
  local names

  names="$(oc get clusterrolebinding -o json 2>/dev/null | jq -r \
    --arg kind "$subject_kind" \
    --arg name "$subject_name" \
    --arg ns "$subject_namespace" '
      .items[]
      | select(any(.subjects[]?;
          .kind == $kind and
          .name == $name and
          (($ns == "") or (.namespace == $ns))))
      | .metadata.name')"

  if [[ -n "$names" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] && oc delete clusterrolebinding "$name" --ignore-not-found
    done <<< "$names"
  fi
}

uninstall_subscription() {
  local namespace="$1"
  local subscription="$2"
  local installed_csv=""

  if ! oc get subscription "$subscription" -n "$namespace" >/dev/null 2>&1; then
    printf 'Subscription %s/%s is already absent.\n' "$namespace" "$subscription"
    return 0
  fi

  installed_csv="$(oc get subscription "$subscription" -n "$namespace" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"

  oc delete subscription "$subscription" -n "$namespace" --ignore-not-found

  if [[ -n "$installed_csv" ]]; then
    oc delete csv "$installed_csv" -n "$namespace" \
      --ignore-not-found --wait=true --timeout=180s || true
  fi
}

uninstall_package_everywhere() {
  local package_name="$1"
  local rows

  rows="$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null | jq -r \
    --arg package "$package_name" '
      .items[]
      | select(.spec.name == $package)
      | [.metadata.namespace, .metadata.name]
      | @tsv')"

  if [[ -z "$rows" ]]; then
    printf 'Package %s is already absent.\n' "$package_name"
    return 0
  fi

  while IFS=$'\t' read -r namespace subscription; do
    [[ -n "$namespace" && -n "$subscription" ]] || continue
    uninstall_subscription "$namespace" "$subscription"
  done <<< "$rows"
}

delete_identities_for_user() {
  local username="$1"
  local identities

  identities="$(oc get identity -o json 2>/dev/null | jq -r \
    --arg username "$username" '
      .items[]
      | select(.user.name == $username)
      | .metadata.name')"

  if [[ -n "$identities" ]]; then
    while IFS= read -r identity; do
      [[ -n "$identity" ]] && oc delete identity "$identity" --ignore-not-found
    done <<< "$identities"
  fi

  oc delete user "$username" --ignore-not-found 2>/dev/null || true
}

remove_mock_rolebindings() {
  local rows

  rows="$(oc get rolebinding -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(any(.subjects[]?;
        (.kind == "Group" and .name == "etherpad-devs") or
        (.kind == "ServiceAccount" and .name == "log-collector")))
    | select(
        (.roleRef.name | test("log|logging"; "i")) or
        (.metadata.name | test("log|logging|etherpad"; "i")))
    | [.metadata.namespace, .metadata.name]
    | @tsv')"

  if [[ -n "$rows" ]]; then
    while IFS=$'\t' read -r namespace name; do
      [[ -n "$namespace" && -n "$name" ]] || continue
      oc delete rolebinding "$name" -n "$namespace" --ignore-not-found
    done <<< "$rows"
  fi
}

wait_namespace_deleted() {
  local namespace="$1"
  local count

  for count in {1..60}; do
    if ! oc get namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  warn "Namespace $namespace is still terminating. Continue after checking its finalizers."
  return 0
}

mkdir -p "$ASSET_DIR" "$MATERIAL_DIR" "$STATE_DIR"
chmod 700 "$MOCK_HOME" "$ASSET_DIR" "$STATE_DIR"

# Preflight before starting either exercise. `lab` must be an executable
# available to this script, not only an interactive shell alias/function.
for required_command in lab oc ldapsearch ldapwhoami openssl timeout getent \
  sha256sum jq python3 git ssh curl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'STOP: Required command is unavailable: %s\n' "$required_command" >&2
    exit 1
  fi
done

run_lab start "$LDAP_LAB_NAME"

log "Saving the RHDS CA and auth-ldap materials before lab finish"
if [[ ! -s "$LDAP_LAB_DIR/rhds_ca.crt" ]]; then
  printf 'STOP: auth-ldap did not create %s/rhds_ca.crt.\n' "$LDAP_LAB_DIR" >&2
  exit 1
fi
openssl x509 -in "$LDAP_LAB_DIR/rhds_ca.crt" -noout >/dev/null
install -m 0644 "$LDAP_LAB_DIR/rhds_ca.crt" "$RHDS_LAB_CA_FILE"
mkdir -p "$MATERIAL_DIR/auth-ldap"
cp -a "$LDAP_LAB_DIR/." "$MATERIAL_DIR/auth-ldap/"

log "Downloading the GitHub RHDS CA and comparing it with auth-ldap"
download_rhds_ca
RHDS_LAB_CA_SHA256="$(openssl x509 -in "$RHDS_LAB_CA_FILE" -outform DER \
  | sha256sum | awk '{print $1}')"
if [[ "$RHDS_LAB_CA_SHA256" != "$RHDS_CA_EXPECTED_SHA256" ]]; then
  printf 'STOP: The CA created by auth-ldap differs from the validated GitHub CA.\n' >&2
  exit 1
fi
printf 'PASS: auth-ldap CA and GitHub CA match.\n'
verify_rhds_tls
verify_rhds_data after-auth-ldap-start

run_lab finish "$LDAP_LAB_NAME"
verify_rhds_tls
verify_rhds_data after-auth-ldap-finish

run_lab start "$LAB_NAME"
check_admin_session
verify_compreview_materials
verify_rhds_tls
verify_rhds_data after-compreview-start

log "Saving the original lab materials"
rm -rf "$MATERIAL_DIR/compreview-review"
mkdir -p "$MATERIAL_DIR/compreview-review"
cp -a "$LAB_DIR/." "$MATERIAL_DIR/compreview-review/"

log "Protecting the lab-provided Loki S3 credentials"
test -s "$LOKI_ENV_SOURCE"
install -m 600 "$LOKI_ENV_SOURCE" "$LOKI_ENV_SAVED"

LOKI_BUCKET="$(bash -c '
  set -a
  source "$1"
  printf "%s" "${bucketnames:-}"
' _ "$LOKI_ENV_SAVED")"

LOKI_ENDPOINT="$(bash -c '
  set -a
  source "$1"
  printf "%s" "${endpoint:-}"
' _ "$LOKI_ENV_SAVED")"

if [[ -z "$LOKI_BUCKET" || -z "$LOKI_ENDPOINT" ]]; then
  printf 'The Loki S3 file does not contain bucketnames and endpoint.\n' >&2
  exit 1
fi

printf 'Protected Loki bucket: %s\n' "$LOKI_BUCKET"
printf 'Protected Loki endpoint: %s\n' "$LOKI_ENDPOINT"

log "Backing up OAuth and comparing the classroom RHDS CA"
oc get oauth cluster -o yaml > "$STATE_DIR/oauth-before-reset.yaml"
oc get oauth cluster -o json > "$STATE_DIR/oauth-before-reset.json"

LDAP_CA_CM="$(jq -r '
  .spec.identityProviders[]?
  | select(.name == "RHDS-EX380")
  | .ldap.ca.name // empty
' "$STATE_DIR/oauth-before-reset.json")"

LDAP_BIND_SECRET="$(jq -r '
  .spec.identityProviders[]?
  | select(.name == "RHDS-EX380")
  | .ldap.bindPassword.name // empty
' "$STATE_DIR/oauth-before-reset.json")"

if [[ -n "$LDAP_CA_CM" ]] && oc get configmap "$LDAP_CA_CM" -n openshift-config >/dev/null 2>&1; then
  oc get configmap "$LDAP_CA_CM" -n openshift-config -o json \
    | jq -r '.data["ca.crt"] // (.data | to_entries[0].value)' \
    > "$STATE_DIR/rhds-ca-from-cluster.crt"

  if ! openssl x509 -in "$STATE_DIR/rhds-ca-from-cluster.crt" \
      -noout >/dev/null 2>&1; then
    printf 'The classroom RHDS CA ConfigMap does not contain a valid certificate.\n' >&2
    exit 1
  fi

  if cmp -s "$RHDS_CA_FILE" "$STATE_DIR/rhds-ca-from-cluster.crt"; then
    printf 'GitHub RHDS CA matches the classroom ConfigMap exactly.\n'
  else
    GITHUB_CA_HASH="$(openssl x509 -in "$RHDS_CA_FILE" -outform DER \
      | sha256sum | awk '{print $1}')"
    CLUSTER_CA_HASH="$(openssl x509 -in "$STATE_DIR/rhds-ca-from-cluster.crt" \
      -outform DER | sha256sum | awk '{print $1}')"

    if [[ "$GITHUB_CA_HASH" != "$CLUSTER_CA_HASH" ]]; then
      printf 'The GitHub RHDS CA does not match the classroom RHDS CA.\n' >&2
      printf 'GitHub:    %s\nClassroom: %s\n' \
        "$GITHUB_CA_HASH" "$CLUSTER_CA_HASH" >&2
      exit 1
    fi

    printf 'GitHub and classroom RHDS certificates match; text formatting differs.\n'
  fi
else
  printf 'No previous RHDS IdP CA ConfigMap to compare; auth-ldap and GitHub CAs already matched.\n'
fi

log "Removing mock LDAP and OIDC providers while preserving the baseline IdP"
python3 - "$STATE_DIR/oauth-before-reset.json" "$STATE_DIR/oauth-provider-reset-patch.json" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
oauth = json.load(open(source))
remove = {"RHDS-EX380", "RHSSO_OIDC"}
providers = [
    provider
    for provider in oauth.get("spec", {}).get("identityProviders", [])
    if provider.get("name") not in remove
]
with open(destination, "w") as stream:
    json.dump({"spec": {"identityProviders": providers}}, stream)
PY

oc patch oauth cluster --type=merge \
  --patch-file "$STATE_DIR/oauth-provider-reset-patch.json"

if [[ -n "$LDAP_CA_CM" ]]; then
  if oc get oauth cluster -o json | jq -e --arg name "$LDAP_CA_CM" \
    'any(.spec.identityProviders[]?; .ldap.ca.name? == $name)' >/dev/null; then
    warn "Keeping ConfigMap $LDAP_CA_CM because another active IdP still references it."
  else
    oc delete configmap "$LDAP_CA_CM" -n openshift-config --ignore-not-found
  fi
fi
if [[ -n "$LDAP_BIND_SECRET" ]]; then
  if oc get oauth cluster -o json | jq -e --arg name "$LDAP_BIND_SECRET" \
    'any(.spec.identityProviders[]?; .ldap.bindPassword.name? == $name)' >/dev/null; then
    warn "Keeping Secret $LDAP_BIND_SECRET because another active IdP still references it."
  else
    oc delete secret "$LDAP_BIND_SECRET" -n openshift-config --ignore-not-found
  fi
fi

delete_identities_for_user kristendelgado
delete_identities_for_user filipmansur

log "Resetting the client certificate exercise"
delete_crb_for_subject Group cluster-monitoring-app
oc delete group cluster-monitoring-app --ignore-not-found 2>/dev/null || true

oc get csr -o json 2>/dev/null \
  | jq -r '
      .items[].metadata.name
      | select(test("^(mon-cert-csr|mon-punit|infra-observer-access|audit-reader-access)$"))' \
  | xargs -r oc delete csr

rm -rf "$MOCK_HOME/mon-punit"
mkdir -p "$MOCK_HOME/mon-punit"

cat > "$ASSET_DIR/dummy-client-csr.yaml" <<'EOF'
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: REPLACE_CSR_NAME
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 604800
  request: REPLACE_BASE64_CSR
  usages:
    - client auth
EOF

log "Resetting OADP while preserving the separate Loki bucket"
OADP_OBJECT_BUCKET=""
OADP_BUCKET=""

if oc get obc backup -n openshift-adp >/dev/null 2>&1; then
  OADP_OBJECT_BUCKET="$(oc get obc backup -n openshift-adp \
    -o jsonpath='{.spec.objectBucketName}')"
  OADP_BUCKET="$(oc get obc backup -n openshift-adp \
    -o jsonpath='{.spec.bucketName}')"

  printf 'OADP bucket scheduled for deletion: %s\n' "$OADP_BUCKET"

  if [[ "$OADP_BUCKET" == "$LOKI_BUCKET" ]]; then
    printf 'REFUSING TO DELETE: OADP and Loki resolve to the same bucket: %s\n' \
      "$OADP_BUCKET" >&2
    exit 1
  fi
fi

if has_resource backups.velero.io; then
  oc delete backups.velero.io --all -n openshift-adp \
    --ignore-not-found --wait=false || true
fi
if has_resource restores.velero.io; then
  oc delete restores.velero.io --all -n openshift-adp \
    --ignore-not-found --wait=false || true
fi
if has_resource schedules.velero.io; then
  oc delete schedules.velero.io --all -n openshift-adp \
    --ignore-not-found --wait=false || true
fi

if has_resource dataprotectionapplications.oadp.openshift.io; then
  oc delete dataprotectionapplications.oadp.openshift.io --all \
    -n openshift-adp --ignore-not-found --wait=true --timeout=240s || true
fi

if oc get obc backup -n openshift-adp >/dev/null 2>&1; then
  oc delete obc backup -n openshift-adp --wait=true --timeout=240s
fi

oc delete secret backup cloud-credentials \
  -n openshift-adp --ignore-not-found 2>/dev/null || true
oc delete configmap backup \
  -n openshift-adp --ignore-not-found 2>/dev/null || true

if [[ -n "$OADP_OBJECT_BUCKET" ]] && oc get objectbucket "$OADP_OBJECT_BUCKET" >/dev/null 2>&1; then
  printf 'ObjectBucket %s still exists after OBC deletion.\n' "$OADP_OBJECT_BUCKET" >&2
  exit 1
fi

uninstall_subscription openshift-adp redhat-oadp-operator

log "Removing the Velero CSI VolumeSnapshotClass labels"
oc label volumesnapshotclass --all \
  velero.io/csi-volumesnapshot-class- 2>/dev/null || true

log "Resetting GitOps and OIDC exercise resources"

# Stop reconciliation first so Argo CD cannot recreate resources while this
# reset removes the objects that it previously managed.
if oc get namespace openshift-gitops >/dev/null 2>&1; then
  oc scale statefulset --all -n openshift-gitops --replicas=0 \
    --timeout=60s 2>/dev/null || true
  oc scale deployment --all -n openshift-gitops --replicas=0 \
    --timeout=60s 2>/dev/null || true
fi

if has_resource applications.argoproj.io; then
  oc get applications.argoproj.io -A -o json 2>/dev/null \
    | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' \
    | while IFS=$'\t' read -r namespace name; do
        [[ -n "$namespace" && -n "$name" ]] || continue
        oc patch applications.argoproj.io "$name" -n "$namespace" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' || true
        oc delete applications.argoproj.io "$name" -n "$namespace" \
          --ignore-not-found --wait=false || true
      done
fi

if has_resource applicationsets.argoproj.io; then
  oc delete applicationsets.argoproj.io --all -A --wait=false || true
fi
if has_resource appprojects.argoproj.io; then
  oc delete appprojects.argoproj.io --all -A --wait=false || true
fi
if has_resource argocds.argoproj.io; then
  oc delete argocds.argoproj.io --all -A --wait=false || true
fi

uninstall_subscription openshift-gitops-operator openshift-gitops-operator

oc delete namespace openshift-gitops --ignore-not-found --wait=false || true
oc delete namespace openshift-gitops-operator --ignore-not-found --wait=false || true

# Repeat the DPA cleanup after stopping Argo CD. This covers a DPA recreated
# between the initial OADP reset and the GitOps shutdown.
if [[ -n "$(oc get dataprotectionapplications.oadp.openshift.io \
  -n openshift-adp -o name 2>/dev/null || true)" ]]; then
  oc delete dataprotectionapplications.oadp.openshift.io --all \
    -n openshift-adp --ignore-not-found --wait=false || true

  for _ in {1..15}; do
    if [[ -z "$(oc get dataprotectionapplications.oadp.openshift.io \
      -n openshift-adp -o name 2>/dev/null || true)" ]]; then
      break
    fi
    sleep 2
  done

  # If the OADP operator disappeared before processing its finalizer, remove
  # only the finalizer from the DPA that this reset is explicitly deleting.
  oc get dataprotectionapplications.oadp.openshift.io \
    -n openshift-adp -o name 2>/dev/null \
    | while read -r resource; do
        [[ -n "$resource" ]] || continue
        warn "Removing the stale finalizer from $resource."
        oc patch "$resource" -n openshift-adp \
          --type=merge -p '{"metadata":{"finalizers":null}}' || true
        oc delete "$resource" -n openshift-adp \
          --ignore-not-found --wait=false || true
      done
fi

log "Removing the previous GitLab mock repository when stored credentials permit it"
GIT_CREDENTIAL="$(printf 'protocol=https\nhost=git.lab.example.com\n\n' \
  | git credential fill 2>/dev/null || true)"
GIT_USERNAME="$(printf '%s\n' "$GIT_CREDENTIAL" \
  | awk -F= '$1 == "username" {sub(/^[^=]*=/, ""); print; exit}')"
GIT_SECRET="$(printf '%s\n' "$GIT_CREDENTIAL" \
  | awk -F= '$1 == "password" {sub(/^[^=]*=/, ""); print; exit}')"

if [[ -n "$GIT_USERNAME" && -n "$GIT_SECRET" ]]; then
  GITLAB_RESPONSE="$(mktemp)"
  GITLAB_API="https://git.lab.example.com/api/v4/projects/developer%2Fsso-compreview"
  GITLAB_STATUS="$(curl -skS -o "$GITLAB_RESPONSE" -w '%{http_code}' \
    -H "PRIVATE-TOKEN: $GIT_SECRET" "$GITLAB_API" || true)"

  if [[ "$GITLAB_STATUS" != "200" && "$GITLAB_STATUS" != "404" ]]; then
    GITLAB_STATUS="$(curl -skS -o "$GITLAB_RESPONSE" -w '%{http_code}' \
      --user "$GIT_USERNAME:$GIT_SECRET" "$GITLAB_API" || true)"
  fi

  if [[ "$GITLAB_STATUS" == "200" ]]; then
    GITLAB_PROJECT_ID="$(jq -r '.id' "$GITLAB_RESPONSE")"
    DELETE_STATUS="$(curl -skS -o /dev/null -w '%{http_code}' \
      -X DELETE -H "PRIVATE-TOKEN: $GIT_SECRET" \
      "https://git.lab.example.com/api/v4/projects/$GITLAB_PROJECT_ID" || true)"

    if [[ "$DELETE_STATUS" != "202" && "$DELETE_STATUS" != "204" ]]; then
      DELETE_STATUS="$(curl -skS -o /dev/null -w '%{http_code}' \
        -X DELETE --user "$GIT_USERNAME:$GIT_SECRET" \
        "https://git.lab.example.com/api/v4/projects/$GITLAB_PROJECT_ID" || true)"
    fi

    if [[ "$DELETE_STATUS" == "202" || "$DELETE_STATUS" == "204" ]]; then
      printf 'Deleted GitLab project developer/sso-compreview.\n'
    else
      warn "GitLab project exists but API deletion returned HTTP $DELETE_STATUS. Delete developer/sso-compreview manually."
    fi
  elif [[ "$GITLAB_STATUS" == "404" ]]; then
    printf 'GitLab project developer/sso-compreview is already absent.\n'
  else
    warn "Could not inspect developer/sso-compreview through the GitLab API (HTTP $GITLAB_STATUS)."
  fi

  rm -f "$GITLAB_RESPONSE"
else
  warn "No stored GitLab credential was found. Delete developer/sso-compreview manually if it exists."
fi

unset GIT_CREDENTIAL GIT_USERNAME GIT_SECRET GITLAB_STATUS GITLAB_PROJECT_ID DELETE_STATUS

log "Resetting logging, Loki, Event Router, and log access resources"
if has_resource clusterlogforwarders.observability.openshift.io; then
  oc delete clusterlogforwarders.observability.openshift.io --all -A \
    --ignore-not-found --wait=false || true
fi
if has_resource clusterlogforwarders.logging.openshift.io; then
  oc delete clusterlogforwarders.logging.openshift.io --all -A \
    --ignore-not-found --wait=false || true
fi
if has_resource lokistacks.loki.grafana.com; then
  oc delete lokistacks.loki.grafana.com --all -A \
    --ignore-not-found --wait=false || true
fi
if has_resource uiplugins.observability.openshift.io; then
  oc delete uiplugins.observability.openshift.io --all -A \
    --ignore-not-found --wait=false || true
fi

delete_crb_for_subject ServiceAccount log-collector openshift-logging
delete_crb_for_subject ServiceAccount eventrouter openshift-logging
remove_mock_rolebindings

oc delete deployment eventrouter -n openshift-logging --ignore-not-found 2>/dev/null || true
oc delete serviceaccount eventrouter log-collector -n openshift-logging \
  --ignore-not-found 2>/dev/null || true
oc delete configmap eventrouter -n openshift-logging --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding event-reader-binding --ignore-not-found 2>/dev/null || true
oc delete clusterrole event-reader --ignore-not-found 2>/dev/null || true

uninstall_subscription openshift-logging cluster-logging
uninstall_subscription openshift-operators-redhat loki-operator
uninstall_package_everywhere cluster-observability-operator

oc delete namespace openshift-logging --ignore-not-found --wait=false || true

log "Writing the Event Router template for the current classroom domain"
cat > "$ASSET_DIR/eventrouter-template.yaml" <<EOF
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: eventrouter-template
  annotations:
    description: A pod forwarding Kubernetes events to OpenShift Logging.
    tags: events,logging
objects:
  - apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: eventrouter
      namespace: \${NAMESPACE}
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: event-reader
    rules:
      - apiGroups: [""]
        resources: ["events"]
        verbs: ["get", "watch", "list"]
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: event-reader-binding
    subjects:
      - kind: ServiceAccount
        name: eventrouter
        namespace: \${NAMESPACE}
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: event-reader
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: eventrouter
      namespace: \${NAMESPACE}
    data:
      config.json: |-
        {
          "sink": "stdout"
        }
  - apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: eventrouter
      namespace: \${NAMESPACE}
      labels:
        component: eventrouter
        logging-infra: eventrouter
        provider: openshift
    spec:
      replicas: 1
      selector:
        matchLabels:
          component: eventrouter
      template:
        metadata:
          labels:
            component: eventrouter
            logging-infra: eventrouter
            provider: openshift
        spec:
          serviceAccountName: eventrouter
          containers:
            - name: kube-eventrouter
              image: \${IMAGE}
              imagePullPolicy: IfNotPresent
              resources:
                requests:
                  cpu: \${CPU}
                  memory: \${MEMORY}
              volumeMounts:
                - name: config-volume
                  mountPath: /etc/eventrouter
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
            - name: config-volume
              configMap:
                name: eventrouter
parameters:
  - name: IMAGE
    value: "$EVENTROUTER_IMAGE"
  - name: CPU
    value: 100m
  - name: MEMORY
    value: 128Mi
  - name: NAMESPACE
    value: openshift-logging
EOF

# This classroom image has been validated by an actual deployment. A direct
# `oc image info` from workstation can lack the credentials used by kubelet.
# Leave deployment to the participant instead of creating a preflight workload.
printf 'Event Router image: %s\n' "$EVENTROUTER_IMAGE"
printf 'Template prepared; Event Router will be deployed by the participant in Task 5.\n'

log "Removing exercise-specific AlertmanagerConfig resources"
if has_resource alertmanagerconfigs.monitoring.coreos.com; then
  oc get alertmanagerconfigs.monitoring.coreos.com -A -o json 2>/dev/null \
    | jq -r '
        .items[]
        | select(.metadata.name | test("persistent|compreview"; "i"))
        | [.metadata.namespace, .metadata.name]
        | @tsv' \
    | while IFS=$'\t' read -r namespace name; do
        [[ -n "$namespace" && -n "$name" ]] || continue
        oc delete alertmanagerconfig "$name" -n "$namespace" --ignore-not-found
      done
fi

ssh -o BatchMode=yes -o ConnectTimeout=5 student@utility.lab.example.com \
  'truncate -s 0 /home/student/persistent_alerts' 2>/dev/null || \
  warn "Could not clear /home/student/persistent_alerts on utility. Clear it manually before Task 7."

log "Preparing the taint troubleshooting exercise"
mapfile -t WORKER_NODES < <(oc get nodes -o name | sed 's#node/##' | grep '^worker' | sort)

if (( ${#WORKER_NODES[@]} == 0 )); then
  printf 'No nodes named worker* were found; cannot prepare Task 8.\n' >&2
  exit 1
fi

for node in "${WORKER_NODES[@]}"; do
  oc adm taint node "$node" dedicated- 2>/dev/null || true
  oc adm taint node "$node" dedicated=app1:NoSchedule --overwrite
done

if oc get namespace chapter1 >/dev/null 2>&1; then
  oc delete namespace chapter1 --wait=false
  wait_namespace_deleted chapter1
fi
oc create namespace chapter1

WORKER_JSON="$(printf '%s\n' "${WORKER_NODES[@]}" | jq -R . | jq -s .)"

python3 - "$ASSET_DIR/taint-webserver.json" "$WORKER_JSON" <<'PY'
import json
import sys

destination = sys.argv[1]
workers = json.loads(sys.argv[2])
manifest = {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": {
        "name": "webserver-app1",
        "namespace": "chapter1",
        "labels": {"app": "webserver-app1", "mock-exam": "taint"},
    },
    "spec": {
        "replicas": 1,
        "selector": {"matchLabels": {"app": "webserver-app1"}},
        "template": {
            "metadata": {"labels": {"app": "webserver-app1"}},
            "spec": {
                "affinity": {
                    "nodeAffinity": {
                        "requiredDuringSchedulingIgnoredDuringExecution": {
                            "nodeSelectorTerms": [{
                                "matchExpressions": [{
                                    "key": "kubernetes.io/hostname",
                                    "operator": "In",
                                    "values": workers,
                                }]
                            }]
                        }
                    }
                },
                "containers": [{
                    "name": "webserver-app1",
                    "image": "registry.lab.example.com:8443/redhattraining/hello-world-nginx:v1.0",
                    "ports": [{"containerPort": 8080}],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "capabilities": {"drop": ["ALL"]},
                    },
                }],
                "securityContext": {
                    "runAsNonRoot": True,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
            },
        },
    },
}
with open(destination, "w") as stream:
    json.dump(manifest, stream, indent=2)
PY

oc apply -f "$ASSET_DIR/taint-webserver.json"

log "Final verification"
printf '\nProtected Loki backend:\n'
printf '  env file : %s\n' "$LOKI_ENV_SAVED"
printf '  bucket   : %s\n' "$LOKI_BUCKET"
printf '  endpoint : %s\n' "$LOKI_ENDPOINT"

printf '\nOADP reset:\n'
oc get obc -n openshift-adp 2>/dev/null || true
oc get dpa -n openshift-adp 2>/dev/null || true

if [[ -n "$(oc get dataprotectionapplications.oadp.openshift.io \
  -n openshift-adp -o name 2>/dev/null || true)" ]]; then
  printf '\nERROR: A DataProtectionApplication still exists after the reset.\n' >&2
  printf 'Inspect it with: oc get dpa -n openshift-adp -o yaml\n' >&2
  exit 1
fi

printf '\nRemaining target operator subscriptions (expected: none):\n'
oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null \
  | jq -r '
      .items[]
      | select(.spec.name == "redhat-oadp-operator" or
               .spec.name == "openshift-gitops-operator" or
               .spec.name == "cluster-logging" or
               .spec.name == "loki-operator" or
               .spec.name == "cluster-observability-operator")
      | [.metadata.namespace, .metadata.name, .spec.name]
      | @tsv' || true

printf '\nVolumeSnapshotClass labels:\n'
oc get volumesnapshotclass \
  -o custom-columns='NAME:.metadata.name,VELERO_LABEL:.metadata.labels.velero\.io/csi-volumesnapshot-class'

printf '\nTaint exercise:\n'
oc get nodes "${WORKER_NODES[@]}" \
  -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
oc get pod -n chapter1 -o wide

printf '\nLDAP assets:\n'
ls -l "$RHDS_CA_FILE" "$RHDS_LAB_CA_FILE"
verify_rhds_tls
verify_rhds_data after-mock-reset

printf '\nPreparation completed. Mock materials are in: %s\n' "$MOCK_HOME"
printf 'Start with Task 1. Do not run lab finish %s during the mock.\n' "$LAB_NAME"
