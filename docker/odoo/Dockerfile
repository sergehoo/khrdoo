# =============================================================================
#  Kaydan ERP — Image Odoo 18 avec dépendances Python OCA (OIDC/SSO)
#  Utilisée uniquement pour activer auth_oidc (Keycloak). Voir docker-compose.oidc.yml
# =============================================================================
FROM odoo:18

USER root

# Dépendances Python requises par auth_oidc (validation des id_token RS256)
RUN pip3 install --no-cache-dir --break-system-packages \
        PyJWT cryptography python-jose \
    || pip3 install --no-cache-dir PyJWT cryptography python-jose

USER odoo
