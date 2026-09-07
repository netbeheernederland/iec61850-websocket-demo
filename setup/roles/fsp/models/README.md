# FSP model files

Every `*.py` in this directory is copied into each `fsp` node at
`/etc/rti/models/` (mounted into the container at `/models`).

Which file a given FSP loads is set per node in `../../nodes.env` via the
`model=` extra, e.g. `model=model.py` -> `MODELPATH=/models/model.py`.
An empty `model=` leaves `MODELPATH` unset (the container falls back to its
built-in default).

`model.py` here is a copy of `modules/fsp01/models/model.py` from the repo
root, which is the model used by `rti-fsp01` in the root `docker-compose.yml`.
