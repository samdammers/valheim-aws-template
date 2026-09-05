# PyNaCl (Ed25519 signature verification for Discord interactions) has no pure-Python
# option we want to hand-roll, and Lambda's runtime doesn't bundle it — so vendor it in
# directly rather than depending on a third-party Lambda Layer of uncertain regional
# availability. Re-runs only when requirements.txt changes.
resource "null_resource" "lambda_dependencies" {
  triggers = {
    requirements_hash = filesha256("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 -m pip install -r ${path.module}/lambda/requirements.txt \
        --target ${path.module}/lambda \
        --platform manylinux2014_x86_64 \
        --implementation cp \
        --python-version 3.12 \
        --abi cp312 \
        --only-binary=:all: \
        --upgrade -q
    EOT
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda/handler.zip"
  excludes    = ["requirements.txt", "handler.zip"]

  depends_on = [null_resource.lambda_dependencies]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/valheim-manager"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_lambda_function" "valheim" {
  function_name    = "valheim-manager"
  description      = "Manage the Valheim EC2 instance: start/stop/status + idle auto-stop"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  handler = "manager.lambda_handler"
  runtime = "python3.12"
  timeout = 30
  # Lambda CPU scales with memory. 128MB left boto3.client("ec2") taking ~3s just to
  # parse EC2's large service model (real CPU-bound work, confirmed via cProfile) —
  # 512MB cuts that dramatically for the routes that do need an EC2 client.
  memory_size = 512
  role        = aws_iam_role.lambda.arn

  # Explicit, not omitted: the AWS provider treats a removed `architectures` attribute
  # as "leave whatever's already deployed" rather than resetting to AWS's true default,
  # so dropping this line wouldn't actually move an existing arm64 function to x86_64.
  # x86_64 matches the manylinux wheel we vendor PyNaCl for above (and the EC2 instance's
  # architecture) — not worth cross-compiling for arm64 at this scale.
  architectures = ["x86_64"]

  environment {
    variables = {
      INSTANCE_ID               = aws_instance.valheim.id
      IDLE_WINDOW_MINUTES       = tostring(var.idle_window_minutes)
      IDLE_GRACE_PERIOD_MINUTES = tostring(var.idle_grace_period_minutes)
      IDLE_THRESHOLD_BYTES      = tostring(var.idle_threshold_bytes)
      DISCORD_PUBLIC_KEY        = var.discord_public_key
      SERVER_ADDRESS            = local.server_fqdn
      CREDENTIALS_SECRET_ARN    = aws_secretsmanager_secret.valheim.arn
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_event_rule" "idle_check" {
  name                = "valheim-idle-check"
  description         = "Periodically check whether the Valheim server is idle and stop it if so"
  schedule_expression = "rate(10 minutes)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "idle_check" {
  rule      = aws_cloudwatch_event_rule.idle_check.name
  target_id = "valheim-lambda"
  arn       = aws_lambda_function.valheim.arn
  input     = jsonencode({ scheduled_action = "check_idle" })
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.valheim.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_check.arn
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.valheim.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.valheim.execution_arn}/*/*"
}
