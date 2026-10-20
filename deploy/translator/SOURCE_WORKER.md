# RE-02 — Controlled source worker (inert by default)

This is a **separate future activation**, not the existing Gemini worker.
The source worker reads authorized public HTML via reviewed site profiles
and stores original chapters with the API's own SQLite file.
The unit template lives at chaptera-translator-source-worker.service.

**Not installed, enabled or started by this PR.** The protected
translator-service.yml and bootstrap-host.sh stay unchanged.

## Required approvals before manual activation

1. [Ararra #83](https://github.com/Lalalalendia/ararra/issues/83):
   site profiles, durable fair queue, SQLite pacing + quota merged with
   exact green CI and installed as the current Ararra release.
2. [Ararra #65](https://github.com/Lalalalendia/ararra/issues/65):
   controlled permitted live metadata fixture per site, robots/TLS/TOC
   coverage, authorization to automate and to access specific contents.
   Royal Road Terms 6.1.7 explicitly require permission to crawl/scrape;
   a robots.txt allowance alone is not a license.
3. Reader service active; available memory **at least 512 MiB** before
   trial startup. The existing 320 MiB translator-install floor is not
   enough evidence to run a third Python process on the small VPS.
4. Free physical disk on SQLite/WAL/temp filesystem at least twice the
   configured global source logical quota + 1 GiB for SQLite/WAL/tmp.
   Existing source quotas track chapter body only, not filesystem usage.
   Real encrypted off-host backup + restore/recovery proof required.
5. One source-worker instance only. No moderator keys, Gemini vault, Drive
   OAuth, no API listener. The unit enforces MemoryHigh=112M,
   MemoryMax=160M, CPUQuota=35%, TasksMax=48, no new privileges.

## Reviewed manual installation; NOT during normal application deployment

After all of the above: copy the **reviewed** GitHub unit to
/root/source-worker.reviewed using a trusted operator transfer. As root:

~~~bash
test -s /root/source-worker.reviewed
test ! -e /etc/systemd/system/chaptera-translator-source-worker.service
install -o root -g root -m 0644 /root/source-worker.reviewed \
  /etc/systemd/system/chaptera-translator-source-worker.service
systemd-analyze verify /etc/systemd/system/chaptera-translator-source-worker.service
systemctl daemon-reload
# DO NOT enable or start it yet.
~~~

The unit is additionally inert until a root-owned
/etc/chaptera-translator/source-collection-enabled marker exists. The
marker is created only after the host/operator has reviewed current
permissions, source worker release, Reader, memory, disk and backup:

~~~bash
install -o root -g root -m 0644 /dev/null \
  /etc/chaptera-translator/source-collection-enabled
systemctl enable --now chaptera-translator-source-worker.service
systemctl is-active chaptera-translator-source-worker.service
systemctl is-active chaptera-reader.service
~~~

Test a short, explicitly permitted source fixture (not a protected novel)
and observe owner-only queue state, per-site pacing and chapter digests.
No bulk parallel start; adding more moderators must only enqueue jobs.

## Monitoring

~~~bash
systemctl show chaptera-translator-source-worker.service \
  -p ActiveState -p NRestarts -p MemoryCurrent -p CPUUsageNSec
awk '/^MemAvailable:/ {printf "MemAvailable: %.0f MiB\n",$2/1024}' /proc/meminfo
df -Pm /var/lib/chaptera-translator
systemctl is-active chaptera-reader.service
~~~

Stop if RAM/disk degrades, Reader is affected, OOM/restarter loops appear,
robots/ToS change, upstream rate limit is encountered, or budget is
exhausted. Do not increase request limits to bypass restrictions.

## Immediate isolated rollback

~~~bash
systemctl stop chaptera-translator-source-worker.service
systemctl disable chaptera-translator-source-worker.service
rm -f /etc/chaptera-translator/source-collection-enabled
systemctl is-active chaptera-reader.service
~~~

Existing source checkpoints, API, Gemini translator, Nginx, Cloud Reader
and server-held credentials must not be modified by source-worker rollback.
