# Notes

In `memory` mode, Floci treats its state as disposable, so `--persist` only provides a mounted directory without enabling durable storage. As a result, Floci writes very little persistent data there and cleans up the Docker volumes it creates when the environment is torn down.
