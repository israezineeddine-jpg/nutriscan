# Graph Report - nutriscan  (2026-10-25)

## Corpus Check
- Corpus is ~3,953 words - fits in a single context window. You may not need a graph.

## Summary
- 80 nodes · 108 edges · 8 communities
- Extraction: 92% EXTRACTED · 7% INFERRED · 1% AMBIGUOUS · INFERRED: 8 edges (avg confidence: 0.91)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Scan & Lookup UI
- Capacitor Dependencies
- APK Build & Install Docs
- Workflow Step Inputs
- Ingredient Risk Scoring
- Workflow Job Structure
- Capacitor CLI Scripts
- Open Food Facts Data

## God Nodes (most connected - your core abstractions)
1. `with` - 10 edges
2. `fetchProduct()` - 9 edges
3. `steps` - 7 edges
4. `displayProduct()` - 7 edges
5. `analyzeFoodProduct()` - 7 edges
6. `html5QrCode scanner (html5-qrcode 2.3.8)` - 6 edges
7. `scripts` - 5 edges
8. `index.html (NutriScan web app)` - 5 edges
9. `analyzeCosmeticProduct()` - 4 edges
10. `100-point health score` - 4 edges

## Surprising Connections (you probably didn't know these)
- `html5QrCode scanner (html5-qrcode 2.3.8)` --conceptually_related_to--> `@capacitor/camera`  [AMBIGUOUS]
  www/index.html → package.json
- `Camera and Internet permissions` --conceptually_related_to--> `html5QrCode scanner (html5-qrcode 2.3.8)`  [INFERRED]
  README.md → www/index.html
- `Local build with Android Studio` --references--> `cap:add`  [INFERRED]
  README.md → package.json
- `Local build with Android Studio` --references--> `cap:sync`  [INFERRED]
  README.md → package.json
- `Local build with Android Studio` --references--> `cap:open`  [INFERRED]
  README.md → package.json

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Barcode scan → lookup → analysis → render** — www_index_html5qrcode, www_index_onscansuccess, www_index_fetchproduct, www_index_displayproduct, www_index_analyzefoodproduct, www_index_analyzecosmeticproduct, www_index_getscoreinfo [EXTRACTED 1.00]
- **Ingredient risk rule tables** — www_index_food_additives, www_index_cosmetic_ingredients, www_index_food_keywords, www_index_risk_levels [EXTRACTED 1.00]
- **APK build and delivery** — readme_github_actions_apk, github_workflows_build_apk, package, readme_sideload_install [INFERRED 0.85]

## Communities (8 total, 0 thin omitted)

### Community 0 - "Scan & Lookup UI"
Cohesion: 0.18
Nodes (17): index.html (NutriScan web app), currentMode state (food | cosmetic), CSS design tokens (dark theme palette), displayProduct(), escapeHtml(), fetchProduct(), getScoreInfo(), html5QrCode scanner (html5-qrcode 2.3.8) (+9 more)

### Community 1 - "Capacitor Dependencies"
Cohesion: 0.19
Nodes (13): dependencies, @capacitor/android@^6.1.2, @capacitor/camera@^6.1.0, @capacitor/core@^6.1.2, description, devDependencies, @capacitor/cli@^6.1.2, name (+5 more)

### Community 2 - "APK Build & Install Docs"
Cohesion: 0.24
Nodes (8): name, branches, True, push, workflow_dispatch, APK build via GitHub Actions, Camera and Internet permissions, Sideload APK on phone (unknown sources)

### Community 3 - "Workflow Step Inputs"
Cohesion: 0.20
Nodes (10): with, distribution, files, java-version, name, node-version, path, retention-days (+2 more)

### Community 4 - "Ingredient Risk Scoring"
Cohesion: 0.33
Nodes (9): analyzeCosmeticProduct(), analyzeFoodProduct(), COSMETIC_INGREDIENTS (INCI regex rules), FOOD_ADDITIVES (E-number risk table), FOOD_KEYWORDS (ingredient-text rules), NOVA processing group, Risk levels 1-4 (safe / warning / negative / danger), Cited sources (CIRC/OMS, EFSA, ANSES, INSERM) (+1 more)

### Community 5 - "Workflow Job Structure"
Cohesion: 0.22
Nodes (9): runs-on, steps, jobs, build, if, name, run, uses (+1 more)

### Community 6 - "Capacitor CLI Scripts"
Cohesion: 0.47
Nodes (6): scripts, build, cap:add, cap:open, cap:sync, Local build with Android Studio

### Community 7 - "Open Food Facts Data"
Cohesion: 0.50
Nodes (4): NutriScan Android app, Open Food Facts data (ODbL), Nutri-Score grade, Open Food Facts API v2

## Ambiguous Edges - Review These
- `@capacitor/camera` → `html5QrCode scanner (html5-qrcode 2.3.8)`  [AMBIGUOUS]
  www/index.html · relation: conceptually_related_to

## Knowledge Gaps
- **4 isolated node(s):** `Stop-scan click handler`, `Manual barcode search handler`, `NOVA processing group`, `Open Beauty Facts API v2`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 26 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `html5QrCode scanner (html5-qrcode 2.3.8)` connect `Scan & Lookup UI` to `Capacitor Dependencies`, `APK Build & Install Docs`?**
  _High betweenness centrality (0.378) - this node is a cross-community bridge._
- **What connects `Stop-scan click handler`, `Manual barcode search handler`, `NOVA processing group` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Why does `jobs` connect `Workflow Job Structure` to `APK Build & Install Docs`?**
  _High betweenness centrality (0.356) - this node is a cross-community bridge._

### Low-confidence Hints
_AMBIGUOUS edges — the extractor was unsure. Verify before acting on these._

- **What is the exact relationship between `@capacitor/camera` and `html5QrCode scanner (html5-qrcode 2.3.8)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._