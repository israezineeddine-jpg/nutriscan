# NutriScan — Application Android

Scanner de codes-barres pour produits alimentaires. Affiche ingrédients, allergènes, additifs, valeurs nutritionnelles et Nutri-Score via l'API Open Food Facts.

## 🚀 Comment obtenir l'APK (méthode recommandée — sans rien installer)

### Étape 1 : Créer un dépôt GitHub

1. Va sur [github.com](https://github.com) et crée un compte si tu n'en as pas
2. Crée un nouveau dépôt public, nomme-le `nutriscan` (ou ce que tu veux)
3. **NE PAS** initialiser avec README

### Étape 2 : Pousser ce projet sur GitHub

Sur ton PC, ouvre un terminal dans le dossier de ce projet :

```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/TON_USERNAME/nutriscan.git
git push -u origin main
```

### Étape 3 : Récupérer l'APK

1. Va sur ton dépôt GitHub → onglet **Actions**
2. Le workflow "Build Android APK" se lance automatiquement (~5-7 minutes)
3. Une fois terminé (✅ vert), deux options :
   - **Onglet Releases** : tu y trouves le fichier `app-debug.apk` à télécharger
   - **Onglet Actions → ton run → Artifacts** : tu trouves `NutriScan-debug-apk.zip`

### Étape 4 : Installer sur ton téléphone

1. Transfère le `.apk` sur ton téléphone (email, Google Drive, USB, etc.)
2. Sur le téléphone : **Paramètres → Sécurité → Sources inconnues** : autoriser
3. Tape sur le `.apk` → Installer
4. Lance NutriScan → autorise la caméra → scanne !

## 🛠 Build local (alternative — si tu as Android Studio)

```bash
npm install
npx cap add android
npx cap sync android
npx cap open android   # ouvre Android Studio
```

Dans Android Studio : **Build → Build Bundle(s)/APK(s) → Build APK(s)**

## 📁 Structure du projet

```
nutriscan/
├── www/
│   └── index.html          ← l'app (HTML/CSS/JS)
├── package.json            ← dépendances Capacitor
├── capacitor.config.json   ← config app (nom, ID, etc.)
├── .github/workflows/
│   └── build-apk.yml       ← compilation auto de l'APK
└── README.md
```

## 🔧 Modifier l'app

Tout est dans `www/index.html`. Modifie, commit, push → un nouvel APK est généré automatiquement.

## 📝 Permissions

L'app demande :
- **Caméra** : pour scanner les codes-barres
- **Internet** : pour interroger Open Food Facts

## ⚖ Licence

Données produits : [Open Food Facts](https://world.openfoodfacts.org) (Open Database License)
