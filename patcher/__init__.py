"""SystemCore Pi 5B image patcher.

Apply Pi 5B-compatible modifications to an existing upstream SystemCore image
without re-running the full build pipeline. Pairs with `build-image.sh`, which
is still the right tool for first-time setup (it builds the 4K-page kernel
once and caches it); `patch-image.py` is for the common case of patching new
upstream releases between kernel bumps.
"""

__version__ = "1.0.0"
