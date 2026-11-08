#!/bin/bash

# Verifier les images attendues avant le test
IMAGE_PROD=$(kubectl get deployment novel-app \
    -o jsonpath='{.spec.template.spec.containers[0].image}') || exit 1

IMAGE_CANARY=$(kubectl get deployment novel-canary \
    -o jsonpath='{.spec.template.spec.containers[0].image}') || exit 1

if [[ "$IMAGE_PROD" != "blentai/hands-on-k8s-canary:1.4" ||
      "$IMAGE_CANARY" != "blentai/hands-on-k8s-canary:1.5" ]]; then
    echo "ERREUR : les versions deployees ne correspondent pas au test 1.4 vers 1.5."
    exit 1
fi

URL="http://ac0699661d9dc41f98a2b70c8f27a584-828929900.eu-west-1.elb.amazonaws.com/"
DURATION=60
TEST_ID="canary-test-$(date +%s)"

START_TIME=$SECONDS

TOTAL_ENVOYEE=0
ECHEC_CURL=0

while (( SECONDS - START_TIME < DURATION )); do
    TOTAL_ENVOYEE=$((TOTAL_ENVOYEE+1))

    if ! curl -s --max-time 5 -A "$TEST_ID" \
        -o /dev/null -w "%{http_code}\n" "$URL"; then
        ECHEC_CURL=$((ECHEC_CURL+1))
    fi
done

echo "Test termine : $TEST_ID"

# Arreter le script si la recuperation des logs a echoue
if ! kubectl logs -n ingress-nginx deployment/ingress-nginx-controller \
    --since=3m > nginx-logs.txt; then 
    echo "ERREUR : impossible de recuperer les logs NGINX."
    exit 1
fi

# Extraire uniquement les requrtes de notre test
grep -F "$TEST_ID" nginx-logs.txt > canary-logs.txt

if [[ ! -s canary-logs.txt ]]; then
    echo "ERREUR : aucune requete du test trouvee."
    exit 1
fi

echo "Nombre de requetes enregistrees dans NGINX :"
TOTAL_LOGS=$(wc -l < canary-logs.txt)

echo " Requetes tentees : $TOTAL_ENVOYEE"
echo " ECHEC Curl : $ECHEC_CURL"
echo " Requetes enregistrees : $TOTAL_LOGS"

if (( ECHEC_CURL > 0 || TOTAL_LOGS != TOTAL_ENVOYEE)); then
    echo "ERREUR : les resultats du test sont incomplets."
    exit 1
fi

# Nombre de requetes par version
TOTAL_REQUETES_PROD=$(grep '\[default-novel-app-service-80\]' canary-logs.txt | grep -vc '\[default-novel-canary-service-80\]')

TOTAL_REQUETES_CANARY=$(grep -c '\[default-novel-canary-service-80\]' canary-logs.txt)

# Verifier que toutes les requetes sont comptabilisees
if ((TOTAL_REQUETES_PROD + TOTAL_REQUETES_CANARY != TOTAL_LOGS)); then
    echo "ERREUR : certaines requetes ne sont pas attribuees"
    exit 1 
fi

# Nombre d'erreurs HTTP par version
ERROR_REQUETES_PROD=$(grep '\[default-novel-app-service-80\]' canary-logs.txt | grep -v '\[default-novel-canary-service-80\]' | awk '$9 ~ /^[45][0-9][0-9]$/ {count++} END {print count+0}')

ERROR_REQUETES_CANARY=$(grep '\[default-novel-canary-service-80\]' canary-logs.txt | awk '$9 ~ /^[45][0-9][0-9]$/ {count++} END {print count+0}')

# Afficher les resultats
echo "Novel 1.4 : $TOTAL_REQUETES_PROD requetes, $ERROR_REQUETES_PROD erreurs"
echo "Novel 1.5 : $TOTAL_REQUETES_CANARY requetes, $ERROR_REQUETES_CANARY erreurs"

# Verifier que les deux versions ont recu des requetes
if (( TOTAL_REQUETES_PROD == 0 || TOTAL_REQUETES_CANARY == 0 )); then
    echo "Erreur : nombre de requetes insuffisant pour comparer les versions."
    exit 1
fi

# Calculer les taux d'erreur en pourcentage
TAUX_REQUETES_PROD=$(awk -v errors="$ERROR_REQUETES_PROD" -v total="$TOTAL_REQUETES_PROD" \
    'BEGIN {printf "%.2f", (errors / total) * 100}')

TAUX_REQUETES_CANARY=$(awk -v errors="$ERROR_REQUETES_CANARY" -v total="$TOTAL_REQUETES_CANARY" \
    'BEGIN {printf "%.2f", (errors / total) * 100}')

echo "Taux d'erreur Novel 1.4 : $TAUX_REQUETES_PROD %"
echo "Taux d'erreur Novel 1.5 : $TAUX_REQUETES_CANARY %"

# Comparer les taux d'erreur
if awk \
    -v errors_prod="$ERROR_REQUETES_PROD" \
    -v total_prod="$TOTAL_REQUETES_PROD" \
    -v errors_canary="$ERROR_REQUETES_CANARY" \
    -v total_canary="$TOTAL_REQUETES_CANARY" \
    'BEGIN {
        taux_prod = errors_prod / total_prod
        taux_canary = errors_canary / total_canary
        exit !(taux_canary <= taux_prod * 1.25)
    }'; then

    echo "SUCCES : Canary 1.5 accepte."
    echo "La nouvelle version peut remplacer la version 1.4."

    # Mettre a jour la production vers Novel 1.5
    if ! kubectl set image deployment/novel-app \
        backend=blentai/hands-on-k8s-canary:1.5; then

        echo "ERREUR : impossible de mettre a jour Novel vers 1.5."
        exit 1
    fi

    # Verifier que les nouveaux Pods sont prets
    if ! kubectl rollout status deployment/novel-app --timeout=120s; then
        echo "ERREUR : les nouveaux Pods Novel 1.5 ne sont pas prets."

        # Revenir a la version stable 1.4
        if ! kubectl set image deployment/novel-app \
            backend=blentai/hands-on-k8s-canary:1.4; then
            echo "ERREUR : retour a Novel 1.4 impossible"
            exit 1
        fi

        if ! kubectl rollout status deployment/novel-app --timeout=120s; then
            echo "ERREUR : le retour a Novel 1.4 a echoue."
            exit 1
        fi

        echo "Retour a novel 1.4 effectue."
        exit 1
    fi

    echo "SUCCES : Novel 1.5 est deploye en production"

    # Supprimer l ingress canary
    if ! kubectl delete ingress novel-canary-ingress; then
        echo " ERREUR : impossible de supprimer l ingress Canary"
        exit 1
    fi

    #Supprimer le deployment et le service Canary
    if ! kubectl delete deployment/novel-canary service/novel-canary-service; then
         echo "ERREUR : impossible de supprimer les ressources Canary."
         exit 1
    fi

    echo "SUCCES : ressources Canary supprimees."
    echo "Novel 1.5 est maintenant la version de production"


else
    echo "ECHEC : Canary 1.5 rejete."
    echo "La version 1.4 doit etre conservee."

    # Supprimer l ingress Canary
    if ! kubectl delete ingress novel-canary-ingress; then
        echo "ERREUR : impossible de supprimer l ingress Canary."
        exit 1
    fi

    # Supprimer le Deployment et le service Canary
    if ! kubectl delete deployment/novel-canary service/novel-canary-service; then
        echo "ERREUR : impossible de supprimer les ressources Canry."
        exit 1
    fi

    echo "SUCCES : Canary supprime."
    echo "Novel 1.4 reste en production"
fi