#!/usr/bin/env bash
#
# Build the demo image and prove it behaves, under the SAME constraints the
# Deployment imposes: non-root, read-only root filesystem, every capability
# dropped.
#
# Running it the easy way proves nothing. The first version of this image
# appeared to work under `docker run` and would have failed in the cluster,
# because with a read-only root filesystem the entrypoint cannot render its
# nginx config and the base image's default site is served instead: no
# /healthz, no /stub_status, no pod identity. See
# app/docker-entrypoint.d/25-assert-config-rendered.sh.
#
# So there are two runs here. One with the mount writable, which must work. One
# with it unwritable, which must FAIL rather than serve the wrong site.
#
set -euo pipefail

ENGINE="${1:-docker}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="eks-gitops-demo-app:validate"
NAME_OK="eks-gitops-validate-ok"
NAME_BAD="eks-gitops-validate-bad"
PORT="${VALIDATE_PORT:-18099}"

cleanup() {
  "$ENGINE" rm -f "$NAME_OK" "$NAME_BAD" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

fails=0
checks=0

ok()   { checks=$((checks+1)); echo "       ok    $1"; }
bad()  { checks=$((checks+1)); echo "       FAIL  $1"; fails=$((fails+1)); }
want() { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

echo "  building $IMAGE with $ENGINE"
"$ENGINE" build -q -t "$IMAGE" app/ >/dev/null

# --------------------------------------------------------------------------
# Negative run first. If this one passes, the positive run below proves nothing
# about the hardening.
# --------------------------------------------------------------------------
echo "  negative run: /etc/nginx/conf.d NOT writable"
set +e
"$ENGINE" run --name "$NAME_BAD" --read-only --user 101:101 --cap-drop=ALL \
  --mount type=tmpfs,dst=/tmp,tmpfs-mode=1777 \
  --mount type=tmpfs,dst=/etc/nginx/conf.d \
  --mount type=tmpfs,dst=/var/cache/nginx,tmpfs-mode=0777 \
  "$IMAGE" >/dev/null 2>&1
neg_status=$?
set -e

if [[ "$neg_status" -ne 0 ]]; then
  ok "container refuses to start when its config cannot be rendered (exit $neg_status)"
else
  bad "container STARTED with an unrenderable config. It would serve the base image's default site with no /healthz."
fi

# --------------------------------------------------------------------------
# Positive run.
# --------------------------------------------------------------------------
echo "  positive run: hardened, with a writable config mount"
"$ENGINE" run -d --name "$NAME_OK" --read-only --user 101:101 --cap-drop=ALL \
  --mount type=tmpfs,dst=/tmp,tmpfs-mode=1777 \
  --mount type=tmpfs,dst=/etc/nginx/conf.d,tmpfs-mode=0777 \
  --mount type=tmpfs,dst=/var/cache/nginx,tmpfs-mode=0777 \
  -e POD_NAME=demo-app-validate-abcde \
  -e POD_NAMESPACE=demo \
  -e NODE_NAME=ip-10-0-12-34.ec2.internal \
  -e POD_IP=10.0.12.207 \
  -e APP_VERSION=sha-validate \
  -e CLUSTER_NAME=validate-cluster \
  -p "127.0.0.1:${PORT}:8080" \
  "$IMAGE" >/dev/null

# Wait for it rather than sleeping a fixed amount.
for _ in $(seq 1 40); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/healthz" 2>/dev/null; then break; fi
  sleep 0.5
done

code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}$1"; }
body() { curl -s "http://127.0.0.1:${PORT}$1"; }

want "GET /healthz"  "$(code /healthz)" "200"
want "GET /readyz"   "$(code /readyz)"  "200"
want "GET /"         "$(code /)"        "200"
want "GET /nope is a 404 (so the 200s above mean something)" "$(code /definitely-not-here)" "404"

# The status page must be unreachable from outside the pod.
want "GET /stub_status from outside is refused" "$(code /stub_status)" "403"

# ...and reachable over loopback, which is how the metrics sidecar reads it.
if "$ENGINE" exec "$NAME_OK" wget -qO- http://127.0.0.1:8080/stub_status 2>/dev/null | grep -q 'Active connections'; then
  ok "/stub_status over loopback returns nginx counters"
else
  bad "/stub_status over loopback did not return counters, so the metrics sidecar would export nothing"
fi

page="$(body /)"

if [[ -z "$page" ]]; then
  bad "GET / returned an empty body"
else
  # An empty response would make a 'no placeholders remain' check pass for the
  # wrong reason, which is why the emptiness check comes first.
  if grep -q '__[A-Z_]*__' <<<"$page"; then
    bad "unsubstituted placeholders left on the page: $(grep -o '__[A-Z_]*__' <<<"$page" | sort -u | tr '\n' ' ')"
  else
    ok "no unsubstituted placeholders on the page"
  fi

  for expected in demo-app-validate-abcde demo ip-10-0-12-34.ec2.internal 10.0.12.207 validate-cluster sha-validate; do
    if grep -qF "$expected" <<<"$page"; then
      ok "page shows $expected"
    else
      bad "page does not show $expected"
    fi
  done
fi

headers="$(curl -sI "http://127.0.0.1:${PORT}/")"
for h in "X-Content-Type-Options: nosniff" "X-Frame-Options: DENY" "Referrer-Policy: no-referrer" "Cache-Control: no-store"; do
  if grep -qiF "$h" <<<"$headers"; then ok "header $h"; else bad "missing header $h"; fi
done

# server_tokens off means the version must not be advertised.
if grep -qiE '^server: nginx/[0-9]' <<<"$headers"; then
  bad "Server header leaks the nginx version"
else
  ok "Server header does not leak a version"
fi

# Confirm it really is running as a non-root user.
uid="$("$ENGINE" exec "$NAME_OK" id -u 2>/dev/null | tr -d '\r')"
if [[ "$uid" == "0" ]]; then bad "container is running as root"; else ok "container runs as uid $uid"; fi

echo "  $checks check(s) on the image"
exit $(( fails > 0 ? 1 : 0 ))
