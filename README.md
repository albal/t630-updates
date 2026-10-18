# Dell 13G firmware repository for iDRAC

Dell's update catalogs no longer list 13th-generation PowerEdge servers (T630,
R630, R730 and so on), so iDRAC can't find updates for them on
downloads.dell.com any more. This project builds a Docker image containing the
**final** firmware for chosen models, taken from the last Dell catalog that
included them, and serves it over HTTP for iDRAC.

Tested with a PowerEdge T630 on iDRAC8 2.86.86.86: iDRAC reads the catalog and
correctly reports no updates when the server is already on the final versions.

## Quick start

```bash
docker run -d --name dell-repo --restart unless-stopped -p 80:80 \
  ghcr.io/albal/t630-updates:t630
```

Check it's working by opening `http://<docker-host>/versions.txt`, which lists
every package and version in the repository.

> Put `-p 80:80` **before** the image name. Anything after the image name is
> passed to the container, not to Docker, and the port won't be published.

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
| `LC023: Cannot access network share` | iDRAC couldn't fetch `Catalog.xml`. Check the IP, the port mapping, the firewall, and that iDRAC has a route to the Docker host. `docker logs dell-repo` shows every request iDRAC makes. |

If the iDRAC firmware is very old, update iDRAC on its own first: download the
iDRAC package listed in `versions.txt` from the container and upload it under
**Update → Local**.

## Other models

On GitHub, go to **Actions → Build image → Run workflow**, and enter models
such as `T630,R730`. The image is tagged with the model list, for example
`:t630-r730`.

To build locally:

```bash
docker build --build-arg MODELS=R730 -t dell-13g-repo:r730 .

# Or create the files without Docker (Python 3.9+, standard library only):
python3 build_repo.py --models T630 --dry-run
python3 build_repo.py --models T630 --out repo
```

`build_repo.py` options (pass them to Docker with
`--build-arg EXTRA_ARGS="..."`):

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
onward. `build_repo.py`:

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

The Dockerfile runs this in a Python build stage and copies the result into an
`nginx:alpine` image. The T630 image is about 4.6 GB.

## Licence

The code in this repository is released under the [MIT License](LICENSE),
© 2026 Al West.

The firmware packages that go into the image are Dell's, under Dell's own
licence terms, and aren't covered by the MIT License. They are unmodified
copies of files Dell publishes on downloads.dell.com.
