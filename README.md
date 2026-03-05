# Datto RMM Agent Remediation Framework

This repository contains a remediation framework designed to monitor and repair Datto RMM agents when the **CagService** becomes non-functional or stops running.

The goal is to provide **safe, automated remediation** while avoiding unnecessary agent reinstalls caused by benign service events.

---

# Background

During normal operation, Datto RMM agents occasionally log **CagService failure events** in the Windows System Event Log.

Through investigation with Datto Support (Ticket **#6736841**), it was determined that:

- Approximately **98% of observed CagService failure events** occurred during normal system state transitions such as:
  - Shutdown
  - Sleep
  - Hibernate
  - Resume

These events were being recorded by the Windows **Service Control Manager**, even though:

- The Datto agent recovered automatically
- The service was already **Running** again by the time remediation scripts executed

Earlier versions of this remediation script interpreted **any failure event within a time window** as justification to reinstall the agent.

This resulted in **unnecessary agent reinstallations**, even when the agent was healthy.

Datto Support confirmed this behavior is related to a known internal issue:

> PT 5134512 — CagService failure events logged during power state transitions.

To address this, the remediation logic was redesigned to require **multiple verification conditions** before reinstalling the agent.

---

# Remediation Logic

The script now performs remediation using **AND-gated logic**.

Full agent remediation occurs **only when BOTH conditions are true:**

1. **CagService is not currently running**
2. **A qualifying CagService failure event exists within the configured lookback window**

If the service is already **Running**, the script **exits without remediation**, regardless of historical failure events.

This ensures benign power-state events do not trigger unnecessary reinstalls.

---

# Script Behavior

The remediation script performs the following steps:

1. Waits **5 minutes** after system startup to allow services to stabilize.
2. Checks the status of **CagService**.
3. If the service is **not running**, attempts a service start.
4. If the start attempt fails:
   - The script checks Windows Event Logs for relevant service failures.
5. If both failure conditions are satisfied:
   - Performs full Datto agent remediation.

Remediation includes:

- Stopping the service
- Backing up the existing agent directory
- Downloading the correct installer using the device **siteUID**
- Reinstalling the agent silently
- Verifying the service is running afterward

---

# Logging

The script generates detailed logs to:

```
C:\ProgramData\Datto_RMM_Logs\
```

Log file naming format:

```
<Domain_or_Tenant>_<DeviceName>_<Timestamp>.log
```

Example:

```
CONTOSO-PC01_20260305_101455.log
```

Logs contain:

- Service state checks
- Event log evidence
- Remediation decisions
- Installer results
- Final service status

---

# Optional Centralized Logging

If a **LambdaUrl** is provided, logs can be uploaded to AWS.

Logs are sent via HTTP POST to a Lambda function which stores them in S3.

Folder structure in S3:

```
ServiceRestarts/<siteUID>/<device>/
Remediations/<siteUID>/<device>/
```

Logs are uploaded **only when action occurs**:

| Action | Upload Location |
|------|------|
| Service restart resolved issue | ServiceRestarts |
| Full remediation executed | Remediations |
| No action required | No upload |

---

# Deployment Options

The script can be deployed through multiple methods depending on environment.

### Group Policy (Recommended for domain environments)

Deployed via **GPO Scheduled Task**:

```
Computer Configuration
  → Preferences
    → Control Panel Settings
      → Scheduled Tasks
```

Runs under:

```
NT AUTHORITY\SYSTEM
```

Triggers:

- At system startup
- Optional daily health check

---

### Intune Deployment

The script can be deployed using:

```
Intune → Devices → Scripts → Platform Scripts
```

Recommended for:

- Azure AD joined devices
- Non-domain laptops

---

### Datto RMM Component

The script can also run as a **Datto RMM component** when agents are already healthy.

This allows:

- On-demand remediation
- Manual troubleshooting
- Controlled deployments

---

# Repository Structure

```
datto-rmm-remediation
│
├── Datto_RMM_Universal_Fix.ps1
│
└── README.md
```

---

# Version History

## v2.1.0 — Remediation Logic Correction

Updated remediation logic based on findings from the Datto RMM investigation regarding CagService failure events occurring during shutdown and power-state transitions.

Changes:

- Implemented **strict AND-gated remediation logic**
- Prevented unnecessary agent reinstalls caused by historical events
- Added **failure event timestamp logging**
- Improved service restart verification
- Adjusted S3 logging behavior to upload logs only when action occurs

Purpose:

Prevent benign shutdown/sleep events from triggering unnecessary agent reinstalls.

---

## v2.0.9 — Initial Universal Remediation Script

Initial release of the Datto RMM Universal Fix script.

Features:

- Detects CagService failures
- Attempts automatic service restart
- Performs full agent reinstall when failures are detected
- Optional AWS Lambda / S3 logging
- Designed for deployment via GPO, Intune, or Datto RMM

---

# Future Improvements

Possible enhancements under consideration:

- Additional telemetry around agent health
- Network connectivity checks prior to remediation
- Extended diagnostic logging for Datto Support
- Optional alerting integrations

---

# Disclaimer

This script is intended to assist in maintaining Datto RMM agent stability in environments where agents may become unhealthy.

It is not an official Datto/Kaseya product component and should be tested prior to large-scale deployment.

---

# Author

Jonathan Myers  
CTMS IT
