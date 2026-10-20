# cmake-dep config for a trusted CI runner that keeps the team mirror filled.
#
# Reads from the mirror first; whatever is missing is downloaded upstream once
# and pushed back (HTTP PUT), so the next developer or job gets it from the LAN.
# Credentials come from the environment (CI secret), not from this file:
#   CMDEP_MIRROR_HTTPHEADER="Authorization: Bearer $MIRROR_TOKEN"

set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")
set(CMDEP_MIRROR_PUSH "https://cmdep.lan.example.com")

# Also publish prebuilt binary packages built here (docs/binary-packages.md).
# Only trusted machines should do this: everyone downloading them runs this code.
set(CMDEP_BINARY_MIRRORS "https://cmdep.lan.example.com")
set(CMDEP_BINARY_PUSH "https://cmdep.lan.example.com")
# Sign what is pushed (key from `cmdep keygen`, provided by the CI secret store,
# file mode 600). Clients verify with CMDEP_BINARY_TRUSTED_KEYS.
# set(CMDEP_BINARY_SIGNING_KEY "$ENV{RUNNER_TEMP}/cmake-dep-signing-key")
