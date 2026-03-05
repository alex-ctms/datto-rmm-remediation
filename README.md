
---

# Version History

## v2.1.0 — Remediation Logic Correction

Changes:

- Implemented **AND-gated remediation logic**
- Prevented unnecessary agent reinstalls
- Added failure event timestamp logging
- Improved restart validation
- Improved S3 log categorization

Purpose:

Prevent remediation from triggering due to benign power-state events.

---

## v2.0.9 — Initial Universal Script

Initial release including:

- Service monitoring
- Restart logic
- Agent reinstall capability
- AWS logging integration

---

# Disclaimer

This script is provided to maintain Datto RMM agent stability in environments experiencing service state inconsistencies.

It is **not an official Datto/Kaseya product component** and should be tested prior to large-scale deployment.

---

# Author

Jonathan Myers  
CTMS IT
