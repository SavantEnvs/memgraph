module;

#include <cstdint>
#include <expected>
#include <map>
#include <optional>
#include <ostream>
#include <string>
#include <string_view>

export module memgraph.utils.aws;

// Network-free stand-in for src/utils/aws.cppm (AWS SDK is not in the offline image); the CSV
// harness never reaches S3, it only needs these declarations for the Reader's CsvSource variant.
export namespace memgraph::utils {

enum class AwsValidationError : uint8_t { AWS_REGION, AWS_ACCESS_KEY, AWS_SECRET_KEY };

inline auto AwsValidationErrorToStr(AwsValidationError) -> std::string { return "AWS support is not built"; }

struct S3Config {
  std::optional<std::string> aws_region;
  std::optional<std::string> aws_access_key;
  std::optional<std::string> aws_secret_key;
  std::optional<std::string> aws_endpoint_url;

  [[nodiscard]] auto Validate() const -> std::optional<AwsValidationError> {
    return AwsValidationError::AWS_REGION;
  }
};

enum class S3ErrorCode : uint8_t { S3_PREFIX_MISSING, BUCKET_OBJECT_KEY_MISSING, S3_API_ERROR };

struct S3Error {
  S3ErrorCode status_code;
  std::string message;
};

inline auto GetS3Object(std::string, S3Config const &, std::ostream &) -> std::expected<void, S3Error> {
  return std::unexpected{S3Error{.status_code = S3ErrorCode::S3_API_ERROR, .message = "AWS support is not built"}};
}

}  // namespace memgraph::utils
