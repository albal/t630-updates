# Dell 13G firmware repository for iDRAC

Dell's update catalogs no longer list 13th-generation PowerEdge servers (T630,
R630, R730 and so on), so iDRAC can't find updates for them on
downloads.dell.com any more. This builds a Docker image containing the
**final** firmware for chosen models, taken from the last Dell catalog that
included them, and serves it over HTTP for iDRAC.

## Use it

```bash
docker run -d --name dell-repo -p 80:80 ghcr.io/<owner>/<repo>:t630
```

In iDRAC8, go to **iDRAC Settings → Update and Rollback → Update**:

| Field             | Value                        |
|-------------------|------------------------------|
| File Location     | HTTP                         |
| HTTP Address      | IP of the Docker host        |
| Catalog Location  | leave blank                  |
| Catalog Filename  | leave blank (`Catalog.xml`)  |

Then click **Check for Update**. To see what's in the repository, open
`http://<docker-host>/versions.txt`.

"SUP029: Firmware versions on server match catalog" means the server is
already on the final versions.

## Other models

On GitHub, go to **Actions → Build image → Run workflow**, and enter models
such as `T630,R730`. The image is tagged with the model list, for example
`:t630-r730`.

To build locally:

```bash
docker build --build-arg MODELS=R730 -t dell-13g-repo:r730 .

# Or create the files without Docker:
python3 build_repo.py --models T630 --out repo --dry-run
python3 build_repo.py --models T630 --out repo
```

Options for `build_repo.py` (they can be passed to Docker with
`--build-arg EXTRA_ARGS="..."`):

- `--all-versions` keeps every version, not just the newest package for each
  device.
- `--include-drivers` also includes Windows OS drivers.
- `--catalog-url` builds from a different Dell catalog.

## How it works

`https://downloads.dell.com/catalog/CatalogIndex.gz` lists Dell's past
catalogs. The last Lifecycle Controller catalog with 13G servers is
**26.06.01** (`FOLDER14611037M/1/Catalog.xml.gz`); 13G is gone from 26.06.08
onward. `build_repo.py`:

1. keeps that catalog's Windows x64 packages for the chosen models, the newest
   per device,
2. downloads them from downloads.dell.com and checks their hashes, and
3. writes a trimmed `Catalog.xml` with relative paths.

The packages are Dell's, under Dell's licence. Keep the image private unless
you've checked that you're allowed to redistribute it.
