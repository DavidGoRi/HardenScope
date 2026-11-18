# Changelog

## 0.1.0 - 2026-11-18

- Local, read-only audit of 33 security settings (system, defense, network, accounts, credentials).
- Baseline in `config/baseline.json` with English and Spanish texts, CIS and Microsoft references and fix commands.
- Weighted score from 0 to 100 and grade from A to F; a failed critical check caps the grade at C.
- JSON record and self-contained bilingual HTML report.
- `-FailOn` exit code for automation and `-FactsPath` to evaluate saved facts.
- Three fictitious demo computers (`tools/New-DemoFacts.ps1`).
- Pester tests and PSScriptAnalyzer in GitHub Actions.
