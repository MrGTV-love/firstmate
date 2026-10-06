#!/bin/bash
set -u
. bin/fm-typesafe-lib.sh
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY /Users/charlesabrooker/firstmate/.env)
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then printf 'authorized_key_unavailable\n'; exit 3; fi
. bin/fm-skill-suggest.sh
