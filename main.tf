/**
 * Creates a Lambda@Edge function to integrate with CloudFront distributions.
 */

/**
 * Lambdas are uploaded to via zip files, so we create a zip out of a given directory.
 * In the future, we may want to source our code from an s3 bucket instead of a local zip.
 */
data "archive_file" "zip_file_for_lambda" {
  type        = "zip"
  output_path = "${var.local_file_dir}/${var.name}.zip"

  dynamic "source" {
    for_each = distinct(flatten([
      for blob in var.file_globs :
      fileset(var.lambda_code_source_dir, blob)
    ]))
    content {
      content = try(
        file("${var.lambda_code_source_dir}/${source.value}"),
        filebase64("${var.lambda_code_source_dir}/${source.value}"),
      )
      filename = source.value
    }
  }

  # Optionally write a `config.json` file if any plaintext params were given
  dynamic "source" {
    for_each = length(keys(var.plaintext_params)) > 0 ? ["true"] : []
    content {
      content  = jsonencode(var.plaintext_params)
      filename = var.config_file_name
    }
  }
}

/**
 * Upload the build artifact zip file to S3.
 *
 * Doing this makes the plans more resiliant, where it won't always
 * appear that the function needs to be updated
 */
resource "aws_s3_object" "artifact" {
  count = var.s3_artifact_bucket == null ? 0 : 1
  bucket = var.s3_artifact_bucket
  key    = "${var.name}.zip"
  source = data.archive_file.zip_file_for_lambda.output_path
  etag   = data.archive_file.zip_file_for_lambda.output_md5
  tags   = var.tags
}

/**
 * Create the Lambda function. Each new apply will publish a new version.
 */
resource "aws_lambda_function" "lambda" {
  function_name = var.name
  description   = var.description

  # Find the file from S3
  s3_bucket         = var.s3_artifact_bucket
  s3_key            = var.s3_artifact_bucket == null ? null : aws_s3_object.artifact.0.id
  s3_object_version = var.s3_artifact_bucket == null ? null : aws_s3_object.artifact.0.version_id

  filename          = var.s3_artifact_bucket == null ? data.archive_file.zip_file_for_lambda.output_path : null

  source_code_hash  = filebase64sha256(data.archive_file.zip_file_for_lambda.output_path)

  publish = true
  handler = var.handler
  runtime = var.runtime
  role    = aws_iam_role.lambda_at_edge.arn
  tags    = var.tags

}

/**
 * Policy to allow AWS to access this lambda function.
 */
data "aws_iam_policy_document" "assume_role_policy_doc" {
  statement {
    sid    = "AllowAwsToAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"

      identifiers = [
        "edgelambda.amazonaws.com",
        "lambda.amazonaws.com",
      ]
    }
  }
}

/**
 * Make a role that AWS services can assume that gives them access to invoke our function.
 * This policy also has permissions to write logs to CloudWatch.
 */
resource "aws_iam_role" "lambda_at_edge" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy_doc.json
  tags               = var.tags
}

/**
 * Allow lambda to write logs.
 */
data "aws_iam_policy_document" "lambda_logs_policy_doc" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",

      # Lambda@Edge logs are logged into Log Groups in the region of the edge location
      # that executes the code. Because of this, we need to allow the lambda role to create
      # Log Groups in other regions
      "logs:CreateLogGroup",
    ]
  }
}

/**
 * Attach the policy giving log write access to the IAM Role
 */
resource "aws_iam_role_policy" "logs_role_policy" {
  name   = "${var.name}at-edge"
  role   = aws_iam_role.lambda_at_edge.id
  policy = data.aws_iam_policy_document.lambda_logs_policy_doc.json
}

/**
 * Creates a Cloudwatch log group for this function to log to.
 * With lambda@edge, only test runs will log to this group. All
 * logs in production will be logged to a log group in the region
 * of the CloudFront edge location handling the request.
 */
resource "aws_cloudwatch_log_group" "log_group" {
  name = "/aws/lambda/${var.name}"
  tags = var.tags
  kms_key_id = var.cloudwatch_log_groups_kms_arn
}

/**
 * Create the secret SSM parameters that can be fetched and decrypted by the lambda function.
 */
resource "aws_ssm_parameter" "params" {
  for_each = var.ssm_params

  description = "param ${each.key} for the lambda function ${var.name}"

  name  = each.key
  value = each.value

  type = "SecureString"
  tier = length(each.value) > 4096 ? "Advanced" : "Standard"

  tags = var.tags
}

/**
 * Create an IAM policy document giving access to read and fetch the SSM params
 */
data "aws_iam_policy_document" "secret_access_policy_doc" {
  count = length(var.ssm_params) > 0 ? 1 : 0

  statement {
    sid    = "AccessParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      for name, outputs in aws_ssm_parameter.params :
      outputs.arn
    ]
  }
}

/**
 * Create a policy from the SSM policy document
 */
resource "aws_iam_policy" "ssm_policy" {
  count = length(var.ssm_params) > 0 ? 1 : 0

  name        = "${var.name}-ssm-policy"
  description = "Gives the lambda ${var.name} access to params from SSM"
  policy      = data.aws_iam_policy_document.secret_access_policy_doc[0].json
}

/**
 * Attach the policy giving SSM param access to the Lambda IAM Role
 */
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  count = length(var.ssm_params) > 0 ? 1 : 0

  role       = aws_iam_role.lambda_at_edge.id
  policy_arn = aws_iam_policy.ssm_policy[0].arn
}
