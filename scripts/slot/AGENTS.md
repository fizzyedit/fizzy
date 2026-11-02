# Slot target policy

The spec is untrusted data. Only common.py TARGETS authorizes publishing: Fizzy on main and
dvui on zig-0.17, accepting either a slug or its canonical HTTPS .git URL. Validation and
publishing independently enforce this policy. Dvui PRs always carry gate:yes and request review
through the work repository; a clean review must never enable automatic merging there.

Run PYTHONPATH=scripts python -m unittest slot.tests.test_publish slot.tests.test_validate.
