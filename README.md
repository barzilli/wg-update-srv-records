# update-srv-records.sh

Publishes the current endpoints of active WireGuard peers in DNS, so that
other peers can look up where to reach them.

The script runs as a loop on the WireGuard hub. Every 90 seconds it compares
the peers that have recently completed a handshake with the records in the
DNS zone, then sends one dynamic update that adds, corrects, or removes
records so the zone matches reality. If nothing changed, nothing is sent.

## DNS layout

Each peer is named by the base32 encoding of its 32-byte public key
(`<label>` below, 56 characters ending in `====`).

| Name | Type | Value | Meaning |
|---|---|---|---|
| `_wireguard._udp.DOMAIN` | PTR | `<label>._wireguard._udp.DOMAIN.` | One per active peer: the list of peers |
| `<label>._wireguard._udp.DOMAIN` | SRV | `0 0 <port> <label>._wireguard._udp.DOMAIN.` | Peer's current endpoint port |
| `<label>._wireguard._udp.DOMAIN` | A | `<address>` | Peer's current endpoint address, if IPv4 |
| `<label>._wireguard._udp.DOMAIN` | AAAA | `<address>` | Peer's current endpoint address, if IPv6 |

A peer has a single endpoint, so it has an A record or an AAAA record, never
both. If its endpoint moves from one address family to the other, the old
record is removed in the same update that adds the new one.

To get the label for a public key:

```sh
echo '<public key>' | base64 -d | base32
```

To look a peer up:

```sh
dig +short SRV <label>._wireguard._udp.wireguard.example.com
dig +short A    <label>._wireguard._udp.wireguard.example.com
dig +short AAAA <label>._wireguard._udp.wireguard.example.com
```

## How a cycle works

1. **Collect active peers.** Parse `wg show all dump` for every interface and
   keep peers whose latest handshake is no more than 200 seconds old.
2. **Read DNS.** One `dig` batch fetches the PTR list and the SRV, A and
   AAAA records of each active peer.
3. **Diff.**
   - Active peer missing from the PTR list: add PTR.
   - Address or port differs from DNS (or is absent): replace A/AAAA or SRV.
   - Address family changed: delete the record of the old family.
   - Peer in the PTR list but no longer active: delete its A, AAAA, SRV
     and PTR.
4. **Apply.** Send all changes as one `nsupdate` transaction, signed with the
   TSIG key, to the local name server.

## Requirements

- bash 4 or later
- `wg` (wireguard-tools)
- `dig` and `nsupdate` (BIND utilities: `dnsutils` / `bind-utils`)
- `base64` and `base32` (coreutils)
- Run as a user that can run `wg show` (normally root) and read the TSIG key
- A local BIND server that is primary for the zone and allows dynamic
  updates with that key, for example:

  ```
  zone "wireguard.example.com" {
      type master;
      file "...";
      update-policy { grant wg-update-key zonesub ANY; };
  };
  ```

  (The key name here is a guess from the key file's name; use the name
  inside your key file.)

## Configuration

Defaults are set at the top of the script and can be overridden with
environment variables.

| Variable | Default | Purpose |
|---|---|---|
| `WG_DNS_DOMAIN` | `wireguard.example.com` | Zone the records live in |
| `WG_DNS_UPDATE_KEY` | `/etc/bind/wg-update-key.key` | TSIG key file for `nsupdate -k` |
| `WG_DNS_SERVER` | `localhost` | Server `dig` queries for current records |
| `WG_DNS_TTL` | `10` | TTL of published records (seconds) |
| `WG_HANDSHAKE_MAX_AGE` | `200` | Handshake age under which a peer counts as active (seconds) |
| `WG_DNS_INTERVAL` | `90` | Pause between cycles (seconds) |

Updates always go to the local name server (`nsupdate -l`), whatever
`WG_DNS_SERVER` is set to.

## Usage

```sh
update-srv-records.sh              # loop forever (normal operation)
update-srv-records.sh --once       # one cycle, then exit
update-srv-records.sh --dry-run    # print the nsupdate batch instead of sending it
update-srv-records.sh --help
```

`--once --dry-run` is the safe way to see what the script would change.

Log messages go to stderr with a timestamp.

### Running under systemd

The script has no daemon logic of its own; `update-srv-records.service`
lets systemd supervise it. The unit expects the script at
`/root/update-srv-records.sh`.

```sh
cp update-srv-records.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now update-srv-records.service
journalctl -u update-srv-records.service      # logs
```

What the unit does:

- Starts after the network is online and after the local name server
  (`named.service`, or `bind9.service` on older Debian/Ubuntu).
- Restarts the script 10 seconds after any exit, except exit status 2
  (missing command or bad option), which restarting cannot fix.
- Reads optional setting overrides from `/etc/default/update-srv-records`,
  one `VAR=value` per line, for example:

  ```
  WG_DNS_INTERVAL=60
  WG_HANDSHAKE_MAX_AGE=180
  ```

- Applies light sandboxing (`NoNewPrivileges`, `ProtectSystem=full`,
  `PrivateTmp`). The script still runs as root, which `wg show` and the
  TSIG key require.

Changes from the original unit: added `Wants=network-online.target` (the
original only ordered after it, which does not guarantee the target is
reached), ordering after the name server, automatic restart, the optional
environment file, and the sandboxing options. The unit name, script path and
install target are unchanged, so it replaces the old file in place.

## Limitations

- **No zoned link-local endpoints.** An endpoint such as
  `[fe80::1%eth0]:51820` cannot be expressed in DNS; the peer is logged and
  skipped.
- **IPv6 addresses are compared as text.** `wg` and `dig` both print the
  standard compressed form, so this matches in practice. If the two ever
  disagreed on formatting, the only effect would be the same AAAA record
  being rewritten every cycle.
- **Peers are active or absent.** A peer drops out of DNS about 200 seconds
  after its last handshake, plus up to one 90-second cycle.
- **The script owns the PTR list.** Any PTR under `_wireguard._udp.DOMAIN`
  whose peer is not currently active is deleted, including ones added by
  hand.

## Changes from the original script

Behaviour for IPv4 peers is unchanged: tested against stubbed `wg`, `dig`
and `nsupdate`, old and new produce the same update batch (the only textual
difference is a redundant TTL dropped from the PTR delete line).

New features:

- **IPv6 endpoints** are published as AAAA records. The original split the
  endpoint on every colon, producing a malformed update that made `nsupdate`
  reject the whole batch whenever an IPv6 peer was active.
- **A and AAAA are queried explicitly**, instead of relying on the name
  server to include them in the additional section of the SRV answer.

Structure and documentation:

- Header documenting purpose, DNS layout, options, configuration and
  requirements; comments on each step and on the input formats parsed.
- Split the single `run_script` function into one function per step, with
  local variables instead of globals leaking between cycles.
- Settings can be overridden from the environment; TTL, handshake age and
  interval are named settings instead of numbers in the code.
- Added `--once`, `--dry-run` and `--help`.
- Replaced deprecated `$[ ]` arithmetic, quoted expansions, consistent
  indentation.

Removed:

- **The WireGuard config-file parser ("step 3").** It built a
  `CONFIGURED_PEERS` list from `/etc/wireguard/*.conf` that nothing ever
  read, so it had no effect on the output.
- Unused variables (`KEY`, the per-interface list) and the `extglob` option
  that only the parser needed.

Fixes for failure cases:

- **`wg` or `dig` failing no longer rewrites the zone.** Previously a failed
  `wg show` looked like "no active peers" and deleted every record, and a
  failed `dig` looked like an empty zone and re-added everything. The cycle
  is now skipped and logged.
- **Interfaces with no peers** no longer cause the next interface's header
  line to be read as a peer.
- Missing commands are reported at start-up instead of failing silently.

## License

MIT. See [LICENSE](LICENSE).
