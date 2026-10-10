#!/usr/bin/env bash
set -euo pipefail

# The image-info module writes custom image metadata to
# /usr/share/butrelinux/image-info.json and patches /usr/lib/os-release.
#
# Required config:
#   variant: the image variant suffix (e.g. "lts", "stable", "nvidia")
#
# Optional config overrides (defaults are provided):
#   vendor, name, pretty_name, tag, like, logo,
#   home_url, support_url, documentation_url

# ---------------------------------------------------------------------------
# Parse module configuration (JSON passed as $1)
# ---------------------------------------------------------------------------

variant=$(jq -r '.variant // empty' <<< "$1")
vendor=$(jq -r '.vendor // "butrelinux"' <<< "$1")
name=$(jq -r '.name // "butrelinux"' <<< "$1")
pretty_name=$(jq -r '.pretty_name // "butrelinux"' <<< "$1")
tag=$(jq -r '.tag // "latest"' <<< "$1")
like=$(jq -r '.like // "rhel fedora"' <<< "$1")
logo=$(jq -r '.logo // "kde-logo-icon"' <<< "$1")
home_url=$(jq -r '.home_url // "https://github.com/butrelinux"' <<< "$1")
support_url=$(jq -r '.support_url // "https://github.com/butrelinux/lab/issues"' <<< "$1")
documentation_url=$(jq -r '.documentation_url // "PLACEHOLDER"' <<< "$1")

# Validate required field
if [[ -z "$variant" || "$variant" == "null" ]]; then
    echo "ERROR: image-info module requires 'variant' to be set."
    exit 1
fi

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

VERSION_ID=$(grep '^VERSION_ID=' /usr/lib/os-release | cut -d'"' -f2)

if [[ -n "${IMAGE_REGISTRY:-}" ]]; then
    image_ref="ostree-image-signed:docker://${IMAGE_REGISTRY}/${variant}"
else
    image_ref="ostree-image-signed:docker://ghcr.io/${vendor}/${variant}"
fi

# ---------------------------------------------------------------------------
# Write image-info.json
# ---------------------------------------------------------------------------

echo "Writing image-info.json for ${variant}..."

mkdir -p /usr/share/butrelinux

cat >/usr/share/butrelinux/image-info.json <<EOF
{
  "image-name": "${variant}",
  "image-vendor": "${vendor}",
  "image-tag": "${tag}",
  "image-ref": "${image_ref}"
}
EOF

# ---------------------------------------------------------------------------
# Patch /usr/lib/os-release
# ---------------------------------------------------------------------------

echo "Patching /usr/lib/os-release..."

sed -i "s|^VARIANT_ID=.*|VARIANT_ID=\"${variant}\"|" /usr/lib/os-release
sed -i "s|^PRETTY_NAME=.*|PRETTY_NAME=\"${pretty_name}\"|" /usr/lib/os-release
sed -i "s|^NAME=.*|NAME=\"${pretty_name}\"|" /usr/lib/os-release
sed -i "s|^ID=.*|ID=${name}|" /usr/lib/os-release
sed -i "s|^ID_LIKE=.*|ID_LIKE=\"${like}\"|" /usr/lib/os-release
sed -i "s|^HOME_URL=.*|HOME_URL=\"${home_url}\"|" /usr/lib/os-release
sed -i "s|^SUPPORT_URL=.*|SUPPORT_URL=\"${support_url}\"|" /usr/lib/os-release
sed -i "s|^LOGO=.*|LOGO=\"${logo}\"|" /usr/lib/os-release
sed -i "s|^DEFAULT_HOSTNAME=.*|DEFAULT_HOSTNAME=\"${name}\"|" /usr/lib/os-release

# Remove upstream Red Hat branding lines
sed -i "/^REDHAT_BUGZILLA_PRODUCT=/d; /^REDHAT_BUGZILLA_PRODUCT_VERSION=/d; /^REDHAT_SUPPORT_PRODUCT=/d; /^REDHAT_SUPPORT_PRODUCT_VERSION=/d" /usr/lib/os-release

# Update CPE_NAME and remaining vendor metadata
sed -i "s|^CPE_NAME=.*|CPE_NAME=\"cpe:2.3:o:butre:${name}:${VERSION_ID}:*:*:*:*:*:*:*\"|" /usr/lib/os-release
sed -i "s|^VENDOR_NAME=.*|VENDOR_NAME=\"butre\"|" /usr/lib/os-release
sed -i "s|^VENDOR_URL=.*|VENDOR_URL=\"${home_url}\"|" /usr/lib/os-release
sed -i "s|^BUG_REPORT_URL=.*|BUG_REPORT_URL=\"${support_url}\"|" /usr/lib/os-release
sed -i "s|^DOCUMENTATION_URL=.*|DOCUMENTATION_URL=\"${documentation_url}\"|" /usr/lib/os-release

echo "image-info module completed successfully."
