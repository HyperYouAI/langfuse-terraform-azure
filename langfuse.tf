locals {
  # The 12 system log tables that exist on the deployed ClickHouse (25.2.1), with the
  # PARTITION BY and ORDER BY copied from the live definitions (read from all 3 pods in US and CA,
  # identical). The template below adds the TTL and SETTINGS.
  # ClickHouse rebuilds a system log table, renaming the old one to *_N, when the configured engine
  # differs from the existing one in any clause, TTL and SETTINGS included. A table whose live
  # definition already equals the rendered engine is expected to keep its name. Any other table is
  # rebuilt on the first apply (for example processors_profile_log, which has a 30-day TTL by default).
  # Re-check this map against system.tables on a ClickHouse upgrade.
  clickhouse_system_log_engines = {
    asynchronous_insert_log = {
      partition  = "event_date"
      order_by   = "(database, `table`, event_date, event_time)"
      ttl_column = "event_date"
    }
    asynchronous_metric_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(metric, event_date, event_time)"
      ttl_column = "event_date"
    }
    error_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    latency_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    metric_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    opentelemetry_span_log = {
      partition  = "toYYYYMM(finish_date)"
      order_by   = "(finish_date, finish_time_us, trace_id)"
      ttl_column = "finish_date"
    }
    part_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    processors_profile_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    query_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    query_metric_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    text_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
    trace_log = {
      partition  = "toYYYYMM(event_date)"
      order_by   = "(event_date, event_time)"
      ttl_column = "event_date"
    }
  }

  # Per-table exceptions. asynchronous_insert_log keeps its live 3-day TTL and live settings
  # (no ttl_only_drop_parts), so its definition is unchanged and ClickHouse does not rebuild it.
  clickhouse_system_log_ttl_days_overrides = {
    asynchronous_insert_log = 3
  }
  clickhouse_system_log_settings_overrides = {
    asynchronous_insert_log = "index_granularity = 8192"
  }

  langfuse_values       = <<EOT
langfuse:
  salt:
    secretKeyRef:
      name: langfuse
      key: salt
  nextauth:
    url: "https://${var.domain}"
    secret:
      secretKeyRef:
        name: langfuse
        key: nextauth-secret
postgresql:
  deploy: false
  host: ${azurerm_private_endpoint.postgres.private_service_connection[0].private_ip_address}:5432
  auth:
    username: ${azurerm_postgresql_flexible_server.this.administrator_login}
    database: langfuse
    existingSecret: langfuse
    secretKeys:
      userPasswordKey: postgres-password
clickhouse:
  persistence:
    size: ${var.clickhouse_disk_size_gb}Gi
  auth:
    existingSecret: langfuse
    existingSecretKey: clickhouse-password
  # Server config for ClickHouse system log retention. Survives pod recreation.
  # Without it the TTL is lost and system.*_log grows without bound (SRE-505).
  # Each engine repeats the live PARTITION BY / ORDER BY and adds the TTL and ttl_only_drop_parts.
  # ttl_only_drop_parts is set per table here, so it does not change Langfuse's own tables.
  # The remove="1" lines are required: ClickHouse merges this file into its default config.xml,
  # which already sets partition_by (and ttl on some tables). ClickHouse refuses to start if
  # engine is combined with any of partition_by/ttl/order_by/storage_policy/settings (Code 36).
  extraOverrides: |
    <clickhouse>
%{for name, e in local.clickhouse_system_log_engines}
      <${name}>
        <database>system</database>
        <table>${name}</table>
        <partition_by remove="1"/>
        <ttl remove="1"/>
        <order_by remove="1"/>
        <storage_policy remove="1"/>
        <settings remove="1"/>
        <engine>ENGINE = MergeTree PARTITION BY ${e.partition} ORDER BY ${e.order_by} TTL ${e.ttl_column} + toIntervalDay(${lookup(local.clickhouse_system_log_ttl_days_overrides, name, var.clickhouse_system_log_ttl_days)}) SETTINGS ${lookup(local.clickhouse_system_log_settings_overrides, name, "index_granularity = 8192, ttl_only_drop_parts = 1")}</engine>
      </${name}>
%{endfor}
    </clickhouse>
redis:
  deploy: false
  host: ${azurerm_redis_cache.this.name}.redis.cache.windows.net
  port: 6380
  tls:
    enabled: true
  auth:
    existingSecret: langfuse
    existingSecretPasswordKey: redis-password
s3:
  deploy: false
  storageProvider: "azure"
  endpoint: https://${azurerm_storage_account.this.name}.blob.core.windows.net
  bucket: ${azurerm_storage_container.this.name}
  region: ${azurerm_storage_account.this.location}
  accessKeyId:
    value: ${azurerm_storage_account.this.name}
  secretAccessKey:
    secretKeyRef:
      name: ${kubernetes_secret.langfuse.metadata[0].name}
      key: storage-access-key
  forcePathStyle: false
  eventUpload:
    prefix: "events/"
  batchExport:
    prefix: "exports/"
  mediaUpload:
    prefix: "media/"
EOT
  encryption_values     = var.use_encryption_key == false ? "" : <<EOT
langfuse:
  encryptionKey:
    secretKeyRef:
      name: ${kubernetes_secret.langfuse.metadata[0].name}
      key: encryption-key
EOT
  additional_env_values = length(var.additional_env) == 0 ? "" : <<EOT
langfuse:
  additionalEnv:
%{for env in var.additional_env}
  - name: ${env.name}
%{if env.value != null}
    value: "${env.value}"
%{endif}
%{if env.valueFrom != null}
    valueFrom:
%{if env.valueFrom.secretKeyRef != null}
      secretKeyRef:
        name: ${env.valueFrom.secretKeyRef.name}
        key: ${env.valueFrom.secretKeyRef.key}
%{endif}
%{if env.valueFrom.configMapKeyRef != null}
      configMapKeyRef:
        name: ${env.valueFrom.configMapKeyRef.name}
        key: ${env.valueFrom.configMapKeyRef.key}
%{endif}
%{endif}
%{endfor}
EOT
}

resource "kubernetes_namespace" "langfuse" {
  metadata {
    name = "langfuse"
  }
}

resource "random_bytes" "salt" {
  # Should be at least 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> SALT
  length = 32
}

resource "random_bytes" "nextauth_secret" {
  # Should be at least 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> NEXTAUTH_SECRET
  length = 32
}

resource "random_bytes" "encryption_key" {
  count = var.use_encryption_key ? 1 : 0
  # Must be exactly 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> ENCRYPTION_KEY
  length = 32
}

resource "kubernetes_secret" "langfuse" {
  metadata {
    name      = "langfuse"
    namespace = "langfuse"
  }

  data = {
    "redis-password"      = azurerm_redis_cache.this.primary_access_key
    "postgres-password"   = azurerm_postgresql_flexible_server.this.administrator_password
    "storage-access-key"  = azurerm_storage_account.this.primary_access_key
    "salt"                = random_bytes.salt.base64
    "nextauth-secret"     = random_bytes.nextauth_secret.base64
    "clickhouse-password" = random_password.clickhouse_password.result
    "encryption-key"      = var.use_encryption_key ? random_bytes.encryption_key[0].hex : ""
  }
}

resource "helm_release" "langfuse" {
  name             = "langfuse"
  repository       = "https://langfuse.github.io/langfuse-k8s"
  version          = var.langfuse_helm_chart_version
  chart            = "langfuse"
  namespace        = "langfuse"
  create_namespace = true

  values = [
    local.langfuse_values,
    local.ingress_values,
    local.encryption_values,
    local.additional_env_values
  ]
}
