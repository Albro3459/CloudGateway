# WireGuard Drift Repair Runbook

Firebase is the product source of truth; `/etc/wireguard/wg0.conf` is the persistent host WireGuard config. Create/delete operations update both in one operation, and there is no startup reconciliation job. If Firebase and host WireGuard state disagree outside an active create/delete operation, that is an incident and must be repaired manually with this runbook.

Secrets hygiene: never paste WireGuard private keys, full WireGuard configs, Firebase credentials, or auth tokens into logs, tickets, or chat. Identify peers by client ID or public key only.

## 1. Detect Drift

On the host, list live peers and persistent peers:

```sh
sudo wg show wg0 peers
sudo grep -A3 '^\[Peer\]' /etc/wireguard/wg0.conf
```

In Firestore, list client docs for the region with `status: active` (collection group `Instances` filtered by `regionId`, or per-user `Users/{uid}/Regions/{regionId}/Instances/{clientId}`).

Match on `clientPublicKey`. Drift cases:

* live `wg0` and `wg0.conf` disagree with each other
* a peer exists on the host with no `active` Firebase client doc
* an `active` Firebase client doc has no peer on the host

Also check `Regions/{regionId}.activeClientCount` against the number of `active` docs.

## 2. Decide Repair Direction

* Host peer with no `active` doc: remove the peer from the host. The product never promised that client.
* `active` doc with no host peer: the stored config is dead. Either re-add the peer using the doc's `clientPublicKey` and assigned tunnel IPs, or set the doc `status` to `failed` (with `lastErrorCode`/`lastErrorMessage`) and have the user recreate the client. Prefer re-adding the peer when the doc data is complete and trusted; prefer recreate when in doubt, since the server never stores client private keys and cannot regenerate configs.
* `wg0.conf` and live `wg0` disagree: `wg0.conf` is the persistent state; sync the live interface to it after confirming `wg0.conf` matches Firebase.

## 3. Repair on the Host (Lock + syncconf)

Hold the same lock the API uses for the whole repair so the control plane cannot mutate WireGuard mid-repair. All commands as root.

```sh
sudo flock /run/cloudlaunch-wireguard.lock bash
```

Inside the locked shell:

1. Back up the current config (mode `0600`, timestamped):

   ```sh
   install -m 600 /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.bak-$(date +%F_%H-%M-%S)"
   ```

2. Write a candidate config with the desired peer set (mode `0600`, must end in `.conf` for validation):

   ```sh
   install -m 600 /etc/wireguard/wg0.conf /etc/wireguard/wg0.candidate.conf
   # edit /etc/wireguard/wg0.candidate.conf: add/remove [Peer] blocks only,
   # leave [Interface] untouched
   ```

3. Validate the candidate:

   ```sh
   wg-quick strip /etc/wireguard/wg0.candidate.conf > /dev/null
   ```

4. Atomically replace the active config:

   ```sh
   mv /etc/wireguard/wg0.candidate.conf /etc/wireguard/wg0.conf
   ```

5. Sync the live interface to the persistent config:

   ```sh
   wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)
   ```

6. Verify:

   ```sh
   wg show wg0 peers
   ```

If the live apply fails, restore the timestamped backup over `wg0.conf` and rerun the `wg syncconf` step against the restored file, then exit the locked shell and investigate before retrying.

Only exit the locked shell after `wg0.conf`, the live interface, and the Firebase updates below are consistent (or the failure is recorded).

## 4. Repair Firebase

Using the Firebase console or Admin SDK (not the frontend):

* Mark abandoned docs: set `status` to `removed` (with `removedAt`) or `failed` (with `lastErrorCode`/`lastErrorMessage`) to match what the host now serves.
* Correct `Regions/{regionId}.activeClientCount` to the number of `active` client docs.
* Set `updatedAt` on every doc you change.

## 5. Record the Incident

Note what drifted, the suspected cause (failed operation, manual host edit, restored volume), and the repair performed — peer public keys and client IDs only, no key material.
