data "aws_iam_account_alias" "current" {}

# Auth0: Client setup
resource "auth0_client" "saml" {
  name               = "AWS SSO: ${data.aws_iam_account_alias.current.account_alias}"
  description        = "SAML provider for the ${data.aws_iam_account_alias.current.account_alias} account"
  callbacks          = [var.auth0_aws_sso_acs_url]
  logo_uri           = "https://ministryofjustice.github.io/assets/moj-crest.png"
  app_type           = "regular_web"
  initiate_login_uri = "https://moj.awsapps.com/start"
  is_first_party     = true

  addons {
    samlp {
      audience    = var.auth0_aws_sso_issuer_url
      destination = var.auth0_aws_sso_acs_url
      recipient   = var.auth0_aws_sso_acs_url

      create_upn_claim                   = false
      passthrough_claims_with_no_mapping = false
      map_unknown_claims_as_is           = false
      map_identities                     = false
      name_identifier_format             = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
      name_identifier_probes = [
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
      ]

      signature_algorithm           = "rsa-sha1"
      digest_algorithm              = "sha1"
      lifetime_in_seconds           = 3600
      sign_response                 = false
      typed_attributes              = true
      include_attribute_name_format = true
    }
  }
}

# Auth0: Management machine-to-machine client (for retrieving access tokens from the IdP)
resource "auth0_client" "idp_token" {
  name           = "Management API: Auth0"
  description    = "Machine-to-machine client for accessing IdP access tokens for validation in Auth0 Actions"
  logo_uri       = "https://ministryofjustice.github.io/assets/moj-crest.png"
  app_type       = "non_interactive"
  is_first_party = true

  grant_types = ["client_credentials"]

  jwt_configuration {
    alg                 = "RS256"
    lifetime_in_seconds = "36000"
  }
}

resource "auth0_client_grant" "idp_grant" {
  client_id = auth0_client.idp_token.id
  audience  = "https://${var.auth0_tenant_domain}/api/v2/"
  scopes    = ["read:user_idp_tokens"]
}

# Get client secret
data "auth0_client" "idp_token" {
  client_id = auth0_client.idp_token.client_id
}

# Auth0: Connection configuration
resource "auth0_connection" "github_saml_connection" {
  name     = "GitHub"
  strategy = "github"
  options {
    client_id     = var.auth0_github_client_id
    client_secret = var.auth0_github_client_secret
    # These are the minimum scopes you need for a GitHub SAML connection and AWS SSO.
    scopes = ["read_user", "read_org", "email", "profile"]
  }
}

resource "auth0_connection" "azure_entraid_connection" {
  display_name   = "Microsoft"
  name           = "azure-entraid"
  strategy       = "waad"
  show_as_button = true
  options {
    identity_api  = "microsoft-identity-platform-v2.0"
    client_id     = var.auth0_azure_entraid_client_id
    client_secret = var.auth0_azure_entraid_client_secret
    app_id        = auth0_client.saml.id
    domain        = var.auth0_azure_entraid_domain
    tenant_domain = var.auth0_azure_entraid_domain

    waad_protocol          = "openid-connect"
    max_groups_to_retrieve = 50
    api_enable_users       = false
    scopes = [
      "basic_profile",
      "ext_groups",

    ]
    set_user_root_attributes               = "on_each_login"
    should_trust_email_verified_connection = "always_set_emails_as_verified"
  }
}

# Auth0 actions
resource "auth0_action" "allow_github_organisations" {
  name    = "Allow specific GitHub Organisations and map SAML attributes"
  runtime = "node18"
  deploy  = true
  code    = file("${path.module}/auth0-actions/allow-github-organisations-and-map-saml.js")

  supported_triggers {
    id      = "post-login"
    version = "v3"
  }

  secrets {
    name  = "AUTH0_MANAGEMENT_CLIENT_ID"
    value = auth0_client.idp_token.client_id
  }

  secrets {
    name  = "AUTH0_MANAGEMENT_CLIENT_SECRET"
    value = data.auth0_client.idp_token.client_secret
  }

  secrets {
    name  = "AUTH0_TENANT_DOMAIN"
    value = var.auth0_tenant_domain
  }

  secrets {
    name  = "ALLOWED_DOMAINS"
    value = jsonencode(var.auth0_allowed_domains)
  }

  secrets {
    name  = "ALLOWED_ORGANISATIONS"
    value = jsonencode(var.auth0_github_allowed_orgs)
  }

  dependencies {
    name    = "@octokit/rest"
    version = "20.0.2"
  }

  dependencies {
    name    = "auth0"
    version = "4.2.0"
  }
}

resource "auth0_trigger_actions" "flow" {
  trigger = "post-login"

  actions {
    id           = auth0_action.allow_github_organisations.id
    display_name = auth0_action.allow_github_organisations.name
  }
}
