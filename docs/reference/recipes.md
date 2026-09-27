# Recipes

Complete configs for common requests, from section 5 of `vestal docs agents`. Each one merges over the built-in defaults, passes `vestal check-config` with no errors or warnings, and renders with `diagnostics: 0`: vestal's tests check every one against fixture data. The same files are in the vestal repository as `examples/showcase/<name>.json`.

Print one with `vestal docs recipe/<name>`. To use it, merge the parts you need into the user's config and keep their other widgets in `views.main.children`.
