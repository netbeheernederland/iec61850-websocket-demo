# FSP model files

Every `*.py` in this directory is copied into each `fsp` node at
`/etc/rti/models/` (mounted into the container at `/models`).

Which file a given FSP loads is set per node in `../../nodes.env` via the
`model=` extra, e.g. `model=model_1.py` -> `MODELPATH=/models/model_1.py`.
An empty `model=` leaves `MODELPATH` unset (the container falls back to its
built-in default).

`model_1.py` and `model_2.py` here are copies of
`modules/fsp01/models/model_1.py` and `modules/fsp02/models/model_2.py` from
the repo root: the models used by `rti-fsp01` and `rti-fsp02` in the root
`docker-compose.yml`.
