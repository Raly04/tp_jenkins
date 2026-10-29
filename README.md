# TP3 – Mini Projet : Jenkins, Docker, Kubernetes

Projet issu du TP3 (ENI, M2 DevOps). L'objectif est de construire un pipeline
CI/CD complet avec Jenkins, Docker et Kubernetes.

## Structure

```
tp_jenkins/
├── jenkins_simple/          # Installation de Jenkins avec docker compose
│   ├── docker-compose.yml   # Image blueocean, port 8080, 3 volumes
│   ├── home/                # Persiste les données de build (monté sur /home)
│   └── jenkins_data/        # Données de jenkins (monté sur /var/jenkins)
└── flask_app/               # Application flask à tester + pipeline Jenkins
    ├── app.py               # Routes '/', '/hello/', '/hello/<username>'
    ├── test.py              # Tests unitaires (unittest)
    ├── requirements.txt
    ├── Dockerfile           # Image python:3.7, user flask non-root
    ├── .dockerignore
    ├── Jenkinsfile          # Pipeline : Test python / Build image / Deploy
    └── kubernetes/
        ├── deployment.yaml  # Déploy. pythontest (image localhost:4000)
        └── service.yaml     # Service NodePort 31000
```

## Déroulement du TP

1. **Jenkins avec docker compose** — dans `jenkins_simple` :
   ```bash
   docker-compose up -d
   docker-compose logs      # récupérer le token admin
   # → http://localhost:8080, installer les plugins recommandés, créer un user
   ```
   Premiers pipelines via l'UI (item de type `pipeline`, script `agent any`,
   stage `Hello` avec `echo 'Hello World'`), puis Blue Ocean : <http://localhost:8080/blue>

2. **Tester l'app flask en local** — dans `flask_app` :
   ```bash
   virtualenv -p python3 venv
   source venv/bin/activate
   pip install -r requirements.txt
   chmod +x app.py test.py
   ./test.py --verbose
   ```

3. **Image docker + registry local** :
   ```bash
   docker build -t flask_hello .
   docker run --rm --name flask_hello -p 5000:5000 flask_hello
   docker run --rm --name flask_hello -p 5000:5000 flask_hello ./test.py --verbose
   docker run -p 4000:5000 registry      # LAISSER TOURNER
   docker tag flask_hello localhost:4000/flask_hello
   docker push localhost:4000/flask_hello
   ```

4. **Jenkins dans Kubernetes** (Helm + chart stable/jenkins) :
   ```bash
   wget https://raw.githubusercontent.com/helm/charts/master/stable/jenkins/values.yaml
   # modifier adminUser, adminPassword, serviceType: NodePort, nodePort: 32000
   kubectl create namespace jenkins
   kubectl config set-context --current --namespace=jenkins
   helm repo add stable https://kubernetes-charts.storage.googleapis.com/
   helm repo update
   helm install --name-template jenkins -f values.yaml stable/jenkins
   # → http://localhost:32000, installer le plugin Blue Ocean
   ```
   Le `values.yaml` de l'installation n'est pas versionné ici.

5. **Pipeline as code** — pousser `flask_app` sur GitHub, puis dans Blue Ocean
   créer un pipeline de type `git` avec l'adresse SSH du dépôt et ajouter la clé
   SSH proposée dans GitHub > Settings > SSH keys. Le `Jenkinsfile` décrit :
   - un pod agent k8s avec 3 conteneurs (`python`, `docker` + socket hôte, `kubectl`)
   - le trigger `pollSCM('* * * * *')` (build à chaque push)
   - **Test python** : `pip install -r requirements.txt` + `python test.py`
   - **Build image** : `docker build` + `push` vers `localhost:4000/pythontest:latest`
   - **Deploy** : `kubectl apply` des manifests `kubernetes/`
   L'app est ensuite accessible sur le NodePort 31000.

6. **Branche feature1 + TDD** — ajouter le test en échec
   (`test_new_route` sur `/feature/<name>`), observer le pipeline rouge sur la
   branche, puis ajouter la route flask `/feature/<username>` dans `app.py`
   (dupliquer `hello_user` et changer la route en `/feature`).

## Note sur l'échec final du TP

Dans `test_new_route`, `name` n'est pas défini dans la fonction (global absent)
→ le test échoue avec une `NameError` même après l'ajout de la route.
Et une fois ce point corrigé, `test_new_route` appelle `/feature/{name}` sur une
route définie uniquement en `/feature/<username>` : il faut bien créer la route
`/feature/<username>` (pas `/feature`).
