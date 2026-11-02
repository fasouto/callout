# Sourced by run.sh and install.sh: the identity to sign with.
#
# Your Apple Development certificate when the Mac has one, so macOS keeps the
# Accessibility permission from one build to the next. Without one, ad hoc,
# and every build has to be allowed again.
#
# release.sh sets cert_kind="Developer ID Application" first and refuses the
# ad hoc fallback itself.

cert_kind=${cert_kind:-Apple Development}

identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\('"$cert_kind"': [^"]*\)".*/\1/p' | head -1)
if [ -n "$identity" ]; then
  # The team is the certificate's organisational unit.
  team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline \
    | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)
else
  identity=-
  team=
fi
