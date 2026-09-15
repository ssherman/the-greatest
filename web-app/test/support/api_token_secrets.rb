# Plaintext secrets whose digests the api_tokens fixtures store. One constant
# per fixture row, so a test authenticates with ApiTokenSecrets::MEMBER and the
# fixture file derives the digest from the same value.
module ApiTokenSecrets
  MEMBER = "tg_#{"m" * 40}".freeze
  MUSIC_ONLY = "tg_#{"u" * 40}".freeze
  EXPIRED = "tg_#{"e" * 40}".freeze
  NON_MEMBER = "tg_#{"n" * 40}".freeze
  SERVICE = "tg_#{"s" * 40}".freeze
end
