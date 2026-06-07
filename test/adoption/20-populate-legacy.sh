#!/usr/bin/env bash
# Task 4 step 2: simulate the legacy maestro<->lakerunner integration the way the
# legacy maestro UI would, via direct DB inserts into the maestro DB.
#
# SCHEMA NOTE (chart/plan finding): the plan called for a row
#   maestro_integrations(type='lakerunner', deployment_id IS NULL)
# but maestro v1.53.0 (the appVersion both the legacy maestro@0.8.22 chart AND
# conductor pin) forbids that with CHECK chk_lakerunner_has_deployment
#   (type <> 'lakerunner' OR deployment_id IS NOT NULL).
# So the detection signal `M_LEGACY = count(... deployment_id IS NULL)` can NEVER
# be > 0 on a real v1.53.0 maestro DB — it is effectively dead. The real legacy
# signal that DOES fire (and that we exercise here) is M_ORGS>0 via a
# maestro_organizations row. We additionally build a fully constraint-valid
# legacy lakerunner integration (source='external_byo' deployment + a site,
# auto_add_to_all_orgs=false so M_SHARED stays 0) so the "integration intact +
# not duplicated" assertion has a real row to check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

SITE_ID="44444444-4444-4444-4444-444444444444"
DEPLOY_ID="33333333-3333-3333-3333-333333333333"

echo "==> [populate] insert legacy maestro org + site + external_byo deployment + integration"
psql_db maestro maestro "
BEGIN;
  -- Legacy org (UI-created). Drives the M_ORGS detection signal (M_STATE=1).
  INSERT INTO maestro_organizations (id, name, slug)
  VALUES ('${LEGACY_ORG}', 'Legacy Org', 'legacy-org')
  ON CONFLICT (id) DO NOTHING;

  -- A site for the customer-brought-their-own (external_byo) deployment.
  INSERT INTO maestro_sites (site_id, org_id, name, mode, purpose, status)
  VALUES ('${SITE_ID}', '${LEGACY_ORG}', 'legacy-site', 'self_managed', 'standard', 'registered')
  ON CONFLICT (site_id) DO NOTHING;

  -- A legacy (non-conductor) lakerunner deployment. source='external_byo':
  --   * connection_owner must be 'customer' (chk_source_connection_owner_lockstep)
  --   * org_id AND site_id must be set (chk_scope_invariant)
  --   * auto_add_to_all_orgs=false (chk_auto_add_only_shared) -> NOT counted by M_SHARED
  INSERT INTO maestro_lakerunner_deployments
    (id, name, source, connection_owner, enabled, is_demo, auto_add_to_all_orgs,
     org_id, site_id, admin_api_url, admin_api_key, query_api_url)
  VALUES ('${DEPLOY_ID}', 'Legacy Lakerunner', 'external_byo', 'customer',
          true, false, false,
          '${LEGACY_ORG}', '${SITE_ID}',
          'http://lr-lakerunner-admin-api:8081', '${LEGACY_KEY}',
          'http://lr-lakerunner-query-api:8080')
  ON CONFLICT (id) DO NOTHING;

  -- The integration row the legacy UI creates, referencing that deployment
  -- (deployment_id NOT NULL satisfies chk_lakerunner_has_deployment).
  INSERT INTO maestro_integrations
    (org_id, type, slug, name, credentials, deployment_id, status)
  VALUES ('${LEGACY_ORG}', 'lakerunner', 'legacy-lakerunner', 'Legacy Lakerunner',
          jsonb_build_object('api_key', '${LEGACY_KEY}'),
          '${DEPLOY_ID}', 'active')
  ON CONFLICT (org_id, type, slug) DO NOTHING;
COMMIT;
"

echo "==> [populate] verify detection signals"
echo "    maestro_organizations (M_ORGS):         $(psql_db maestro maestro "SELECT count(*) FROM maestro_organizations;")"
echo "    lakerunner integrations:                $(psql_db maestro maestro "SELECT count(*) FROM maestro_integrations WHERE type='lakerunner';")"
echo "    shared_cardinal deployments (M_SHARED): $(psql_db maestro maestro "SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal' AND enabled AND is_demo=false AND auto_add_to_all_orgs AND btrim(coalesce(admin_api_url,''))<>'' AND btrim(coalesce(admin_api_key,''))<>'';")"
psql_db maestro maestro "SELECT type, deployment_id IS NOT NULL AS has_deploy, slug FROM maestro_integrations;" | sed 's/^/    integ: /'
echo "[populate] done"
