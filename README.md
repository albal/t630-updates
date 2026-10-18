# Dell 13G firmware repository for iDRAC

Dell's update catalogs no longer list 13th-generation PowerEdge servers (T630,
R630, R730 and so on), so iDRAC can't find updates for them on
downloads.dell.com any more. This container downloads the **final** firmware
for chosen models from Dell, taken from the last Dell catalog that included
them, and serves it over HTTP for iDRAC.

The image contains no Dell files. The firmware is downloaded straight from
downloads.dell.com into a volume when the container first starts.

Tested with a PowerEdge T630 on iDRAC8 2.86.86.86: iDRAC reads the catalog and
correctly reports no updates when the server is already on the final versions.

## Quick start

```bash
docker run -d --name dell-repo --restart unless-stopped \
  -p 80:80 -v dell-firmware:/repo -e MODELS=T630 \
  ghcr.io/albal/t630-updates:latest
```

On first start the container downloads about 4.6 GB per model, which takes a
minute or two on a fast connection. Follow it with `docker logs -f dell-repo`.
It's ready when the log says `Serving /repo on port 80` and `docker ps` shows
the container as `healthy`. The `dell-firmware` volume keeps the files, so
later restarts skip the download.

Check it's working by opening `http://<docker-host>/versions.txt`, which lists
every package and version in the repository.

> Put `-p`, `-v` and `-e` **before** the image name. Anything after the image
> name is passed to the container, not to Docker.

### Settings

| Variable | Default | Effect |
|----------|---------|--------|
| `MODELS` | `T630` | Comma-separated models, e.g. `T630,R730`. Changing it rebuilds the repository on next start. |
| `REFRESH` | `no` | `yes` re-checks every file against Dell's hashes and re-downloads any that are missing or damaged. |
| `EXTRA_ARGS` | | Extra `build_repo.py` options, e.g. `--all-versions` or `--include-drivers`. |
| `CATALOG_URL` | last 13G catalog | Build from a different Dell catalog. |

## Update a server from iDRAC8

In iDRAC, go to **iDRAC Settings → Update and Rollback → Update**:

| Field             | Value                        |
|-------------------|------------------------------|
| File Location     | HTTP                         |
| HTTP Address      | IP of the Docker host        |
| User Name / Password | leave blank               |
| Catalog Location  | leave blank                  |
| Catalog Filename  | leave blank (`Catalog.xml`)  |

Click **Check for Update**, tick the updates you want, and install them.

Or use racadm over SSH to the iDRAC:

```bash
# Compare only; installs nothing
racadm update -f Catalog.xml -e <docker-host> -t HTTP --verifycatalog
racadm update viewreport

# Install everything applicable and reboot
racadm update -f Catalog.xml -e <docker-host> -t HTTP -a TRUE
```

### Messages you might see

| Message | Meaning |
|---------|---------|
| `SUP029: Firmware versions on server match catalog` | The server is already on the final versions. Nothing to do. |
| `LC023: Cannot access network share` | iDRAC couldn't fetch `Catalog.xml`. Check that the download has finished, then the IP, the port mapping, the firewall, and that iDRAC has a route to the Docker host. `docker logs dell-repo` shows every request iDRAC makes. |

If the iDRAC firmware is very old, update iDRAC on its own first: download the
iDRAC package listed in `versions.txt` from the container and upload it under
**Update → Local**.

## Build it yourself

```bash
docker build -t t630-updates .
docker run -d -p 80:80 -v dell-firmware:/repo -e MODELS=T630 t630-updates

# Or create the repository without Docker (Python 3.9+, standard library only):
python3 build_repo.py --models T630 --dry-run
python3 build_repo.py --models T630 --out repo
```

`build_repo.py` options:

| Option | Effect |
|--------|--------|
| `--models T630,R730` | Models to include. Default `T630`. |
| `--all-versions` | Keep every version, not just the newest per device. |
| `--include-drivers` | Also include Windows OS driver packages. |
| `--catalog-url URL` | Build from a different Dell catalog. |
| `--jobs N` | Parallel downloads. Default 8. |
| `--dry-run` | List what would be downloaded, then exit. |

## How it works

`https://downloads.dell.com/catalog/CatalogIndex.gz` lists Dell's past
catalogs. The last Lifecycle Controller catalog with 13G servers is
**26.06.01** (`FOLDER14611037M/1/Catalog.xml.gz`); 13G is gone from 26.06.08
onward. When the container starts, `build_repo.py`:

1. Downloads that catalog and looks up each model's system ID (T630 is `0602`).
2. Keeps the Windows x64 update packages for those models. These are the
   packages iDRAC installs.
3. For each device, keeps only the newest package by **release date**. The
   catalog's `dateTime` attribute changes whenever Dell repackages an entry,
   so it can't be used to tell which firmware is newer.
4. Removes devices from any kept package that has a newer package for them, so
   iDRAC never offers a downgrade.
5. Downloads the packages from downloads.dell.com, checks their hashes, and
   writes a trimmed `Catalog.xml` (UTF-16, relative paths) plus `versions.txt`.
   `Catalog.xml` is written last, so iDRAC never sees a half-built repository.

nginx then serves the `/repo` volume.

## Licence

The code in this repository is released under the [MIT License](LICENSE),
© 2026 Al West.

Neither this repository nor its Docker image contains any Dell software. The
firmware packages are downloaded directly from Dell by whoever runs the
container, and remain under Dell's own licence terms.
