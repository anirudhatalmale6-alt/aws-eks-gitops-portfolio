#!/bin/sh
#
# Fail loudly instead of serving the wrong site
# =============================================
#
# This script exists because of a real failure that is very easy to ship.
#
# The image renders /etc/nginx/templates/default.conf.template into
# /etc/nginx/conf.d/default.conf at container start. Running with
# readOnlyRootFilesystem means conf.d has to be a writable mount, and a
# Kubernetes emptyDir arrives owned by root:root while this container runs as
# uid 101. envsubst then cannot write, and the image's own script reports:
#
#   20-envsubst-on-templates.sh: ERROR: /etc/nginx/templates exists,
#                                but /etc/nginx/conf.d is not writable
#
# and CARRIES ON. nginx starts, falls back to the packaged default.conf, and
# serves a working-looking site with no /healthz, no /stub_status and no pod
# identity. Probes then fail with a bare 404 and the actual cause is one line
# buried in the startup log.
#
# So: assert the rendered config is really in place, and if it is not, print the
# diagnosis and the fix and refuse to start. A CrashLoopBackOff with a clear
# message beats a Running pod serving the wrong thing.
#
set -eu

CONF="/etc/nginx/conf.d/default.conf"
MARKER="__POD_NAME__"

if [ ! -f "$CONF" ]; then
  echo >&2 "25-assert-config-rendered.sh: FATAL: $CONF does not exist."
  echo >&2 "  The template was never rendered. Is /etc/nginx/conf.d mounted and writable by uid $(id -u)?"
  exit 1
fi

if ! grep -q "$MARKER" "$CONF"; then
  cat >&2 <<EOF
25-assert-config-rendered.sh: FATAL: $CONF is not the rendered template.

nginx would start and serve the base image's default site: no /healthz, no
/readyz, no /stub_status, and no pod identity on the page. Probes would fail
with a 404 and nothing would say why. Refusing to start instead.

Most likely cause: /etc/nginx/conf.d is not writable by this container's user
(uid $(id -u), gid $(id -g)), so the image skipped envsubst.

In Kubernetes, an emptyDir is created root:root. Add this to the POD level
securityContext so the mount is group-owned by the container's group:

  securityContext:
    fsGroup: 101
    fsGroupChangePolicy: OnRootMismatch

With docker or podman, make the tmpfs world-writable. Note that podman rejects
the uid= tmpfs option that docker accepts, so tmpfs-mode is the portable form:

  --mount type=tmpfs,dst=/etc/nginx/conf.d,tmpfs-mode=0777

Current state of /etc/nginx/conf.d:
$(ls -ld /etc/nginx/conf.d)
$(ls -l /etc/nginx/conf.d)
EOF
  exit 1
fi

echo "25-assert-config-rendered.sh: rendered config confirmed in $CONF"
