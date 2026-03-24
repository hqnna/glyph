# ─────────────────────────────────────────
# example.cfg — Comprehensive example file
# ─────────────────────────────────────────

# ── Runes (constant variables) ───────────

$defaults: {
  port: 8080
  timeout: 30.5
  theme: "dark"
  language: "en"
  log_targets: ["password", "token", "secret"]
  base_uid: 0
}

# ── App metadata ──────────────────────────

app: {
  name: "MyApp"
  version: "2.4.1"
  debug: false
  port: $defaults.port
  max_connections: 200
  timeout: $defaults.timeout
  description: nil
}

# ── Database configuration ────────────────

database: {
  host: "localhost"
  port: 5432
  name: "myapp_db"
  user: "admin"
  password: "s3cr3t"
  ssl: true
  pool_size: 10
  idle_timeout: 600.0
  replica: nil

  # Connection retry settings
  retry: {
    enabled: true
    attempts: 3
    delay: 1.5
  }
}

# ── Authentication ────────────────────────

auth: {
  enabled: true
  session_duration: 60 * 60 * 24
  require_email_verification: true
  allow_guest: false
  secret: "change-me-in-production"

  # Supported OAuth providers
  providers: [
    "google",
    "github",
    "discord",
  ]

  # Roles available in the system
  roles: [
    "guest",
    "user",
    "moderator",
    "admin",
  ]
}

# ── Users ─────────────────────────────────

users: [
  {
    uid: $defaults.base_uid + 1
    name: "Alice"
    email: "alice@example.com"
    admin: true
    active: true
    score: 98.6
    nickname: nil

    inventory: [
      "sword",
      "shield",
      "potion",
    ]

    settings: {
      theme: $defaults.theme
      notifications: true
      language: $defaults.language
    }
  },

  {
    uid: $defaults.base_uid + 2
    name: "Bob"
    email: "bob@example.com"
    admin: false
    active: true
    score: 74.2
    nickname: "bobby"

    inventory: [
      "bow",
      "arrows",
    ]

    settings: {
      theme: "light"
      notifications: false
      language: "fr"
    }
  },

  {
    uid: $defaults.base_uid + 3
    name: "Carol"
    email: "carol@example.com"
    admin: false
    active: false
    score: 0.0
    nickname: nil

    # New user — inventory is empty
    inventory: []

    settings: {
      theme: "system"
      notifications: true
      language: "de"
    }
  },
]

# ── Feature flags ─────────────────────────

features: {
  new_dashboard: true
  legacy_api: false
  beta_editor: true
  analytics: true
  maintenance_mode: false
}

# ── Logging ───────────────────────────────

logging: {
  level: "info"
  pretty: false
  output: "stdout"
  max_file_size_mb: 100
  rotate: true

  # Fields to redact from logs (reusing first 3 from defaults)
  redact: [
    $defaults.log_targets[0],
    $defaults.log_targets[1],
    $defaults.log_targets[2],
    "credit_card",
  ]
}

# ── Server limits ─────────────────────────

limits: {
  max_upload_mb: 25
  rate_limit_per_minute: 60
  max_body_size: pow(2, 20)
  request_timeout: 15.0
  enabled: true
  burst_allowance: nil
}

# ── References ────────────────────────────

# References use @ to point to previously defined fields.
# They resolve from the current scope outward to global scope.

monitoring: {
  target_app: @app.name
  target_port: @app.port
  db_host: @database.host
  db_ssl: @database.ssl
  auth_enabled: @auth.enabled
  first_provider: @auth.providers[0]
  dashboard_enabled: @features.new_dashboard
  log_level: @logging.level
}
