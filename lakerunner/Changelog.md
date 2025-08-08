# Changelog

## 0.2.36

* Add a configurable pod termination grace period, default to 600 seconds
  for ingest, and 300 seconds for other processing workers.  Non-processing
  pods are 120 seconds.
