pipeline {
    agent any

    /*
     * This pipeline owns application deployment revisions.
     *
     * Terraform owns the infrastructure and baseline ECS services.
     * Jenkins builds new application images, registers new task-definition
     * revisions, and deploys those revisions to the existing services.
     */
    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'

        PROJECT_NAME = 'ecs-fargate-cicd'

        FRONTEND_REPOSITORY = 'ecs-fargate-cicd-frontend'
        BACKEND_REPOSITORY  = 'ecs-fargate-cicd-backend'

        ECS_CLUSTER      = 'ecs-fargate-cicd-cluster'
        FRONTEND_SERVICE = 'ecs-fargate-cicd-frontend'
        BACKEND_SERVICE  = 'ecs-fargate-cicd-backend'

        FRONTEND_TASK_FAMILY = 'ecs-fargate-cicd-frontend'
        BACKEND_TASK_FAMILY  = 'ecs-fargate-cicd-backend'

        ALB_NAME = 'ecs-fargate-cicd-alb'
    }

    stages {

        stage('Checkout') {
            steps {
                /*
                 * SCM credentials are configured on the Jenkins job.
                 * No GitHub token is stored in this Jenkinsfile.
                 */
                checkout scm

                script {
                    /*
                     * Each image tag contains:
                     *
                     *   Git commit -> source traceability
                     *   Jenkins build number -> unique immutable ECR tag
                     *
                     * Example:
                     *   8d37e5f20a11-14
                     */
                    env.IMAGE_TAG =
                        "${env.GIT_COMMIT.take(12)}-${env.BUILD_NUMBER}"
                }

                sh '''
                    set -eu

                    echo "Git commit: $GIT_COMMIT"
                    echo "Image tag:  $IMAGE_TAG"
                '''
            }
        }


        stage('Verify AWS Identity') {
            steps {
                /*
                 * Jenkins authenticates through the EC2 instance profile.
                 * No AWS access key is stored in Jenkins.
                 */
                sh '''
                    set -eu

                    aws sts get-caller-identity
                '''
            }
        }


        stage('Checkov IaC Scan') {
            steps {
                /*
                 * Checkov provides IaC visibility before application deployment.
                 *
                 * The current challenge environment contains documented
                 * accepted tradeoffs such as public HTTP and public Jenkins
                 * access. Checkov therefore reports findings here without
                 * blocking the deployment.
                 *
                 * Findings should later be classified as:
                 *   fix-now
                 *   accepted-with-rationale
                 */
                sh '''
                    set -eu

                    checkov \
                      --directory terraform/infrastructure \
                      --framework terraform \
                      --soft-fail
                '''
            }
        }


        stage('Build Images') {
            steps {
                /*
                 * Docker performs the actual container builds.
                 * Jenkins coordinates the build process.
                 */
                sh '''
                    set -eu

                    docker build \
                      --pull \
                      -t frontend:$IMAGE_TAG \
                      ./frontend

                    docker build \
                      --pull \
                      -t backend:$IMAGE_TAG \
                      ./backend
                '''
            }
        }


        stage('Trivy Image Security Gate') {
            steps {
                /*
                 * HIGH and CRITICAL runtime-image findings block deployment.
                 *
                 * --ignore-unfixed prevents the pipeline from failing on a
                 * vulnerability for which no upstream remediation exists yet.
                 */
                sh '''
                    set -eu

                    trivy image \
                      --severity HIGH,CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      frontend:$IMAGE_TAG

                    trivy image \
                      --severity HIGH,CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      backend:$IMAGE_TAG
                '''
            }
        }


        stage('Authenticate to ECR') {
            steps {
                script {
                    env.AWS_ACCOUNT_ID = sh(
                        script: '''
                            aws sts get-caller-identity \
                              --query Account \
                              --output text
                        ''',
                        returnStdout: true
                    ).trim()

                    env.ECR_REGISTRY =
                        "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_DEFAULT_REGION}.amazonaws.com"
                }

                /*
                 * The password returned by get-login-password is temporary.
                 * Docker receives it over stdin rather than through a command
                 * argument or repository file.
                 */
                sh '''
                    set -eu

                    aws ecr get-login-password \
                      --region "$AWS_DEFAULT_REGION" \
                    | docker login \
                        --username AWS \
                        --password-stdin "$ECR_REGISTRY"
                '''
            }
        }


        stage('Push Immutable Images') {
            steps {
                sh '''
                    set -eu

                    FRONTEND_IMAGE="$ECR_REGISTRY/$FRONTEND_REPOSITORY:$IMAGE_TAG"
                    BACKEND_IMAGE="$ECR_REGISTRY/$BACKEND_REPOSITORY:$IMAGE_TAG"

                    docker tag \
                      frontend:$IMAGE_TAG \
                      "$FRONTEND_IMAGE"

                    docker tag \
                      backend:$IMAGE_TAG \
                      "$BACKEND_IMAGE"

                    docker push "$FRONTEND_IMAGE"
                    docker push "$BACKEND_IMAGE"

                    echo "Frontend image: $FRONTEND_IMAGE"
                    echo "Backend image:  $BACKEND_IMAGE"
                '''
            }
        }


        stage('Register Task Definitions') {
            steps {
                /*
                 * Start from the currently deployed task definitions rather
                 * than rebuilding the entire JSON document inside Jenkins.
                 *
                 * Only the application image URI changes.
                 *
                 * AWS response-only task-definition fields are removed before
                 * the document is submitted to RegisterTaskDefinition.
                 */
                sh '''
                    set -eu

                    FRONTEND_IMAGE="$ECR_REGISTRY/$FRONTEND_REPOSITORY:$IMAGE_TAG"
                    BACKEND_IMAGE="$ECR_REGISTRY/$BACKEND_REPOSITORY:$IMAGE_TAG"

                    register_revision() {
                        FAMILY="$1"
                        CONTAINER="$2"
                        IMAGE="$3"
                        PREFIX="$4"

                        aws ecs describe-task-definition \
                          --task-definition "$FAMILY" \
                          --query taskDefinition \
                          > "$PREFIX-current.json"

                        jq \
                          --arg IMAGE "$IMAGE" \
                          --arg CONTAINER "$CONTAINER" \
                          '
                          .containerDefinitions = (
                            .containerDefinitions
                            | map(
                                if .name == $CONTAINER
                                then .image = $IMAGE
                                else .
                                end
                              )
                          )
                          |
                          {
                            family,
                            taskRoleArn,
                            executionRoleArn,
                            networkMode,
                            containerDefinitions,
                            volumes,
                            placementConstraints,
                            requiresCompatibilities,
                            cpu,
                            memory,
                            pidMode,
                            ipcMode,
                            proxyConfiguration,
                            inferenceAccelerators,
                            ephemeralStorage,
                            runtimePlatform
                          }
                          |
                          with_entries(select(.value != null))
                          ' \
                          "$PREFIX-current.json" \
                          > "$PREFIX-new.json"

                        aws ecs register-task-definition \
                          --cli-input-json "file://$PREFIX-new.json" \
                          --query 'taskDefinition.taskDefinitionArn' \
                          --output text \
                          > "$PREFIX-task-definition-arn.txt"
                    }

                    register_revision \
                      "$FRONTEND_TASK_FAMILY" \
                      frontend \
                      "$FRONTEND_IMAGE" \
                      frontend

                    register_revision \
                      "$BACKEND_TASK_FAMILY" \
                      backend \
                      "$BACKEND_IMAGE" \
                      backend

                    echo "Frontend revision:"
                    cat frontend-task-definition-arn.txt

                    echo "Backend revision:"
                    cat backend-task-definition-arn.txt
                '''
            }
        }


        stage('Deploy to ECS') {
            steps {
                /*
                 * Updating the service task definition starts an ECS rolling
                 * deployment.
                 */
                sh '''
                    set -eu

                    FRONTEND_TASK_DEFINITION=$(
                      cat frontend-task-definition-arn.txt
                    )

                    BACKEND_TASK_DEFINITION=$(
                      cat backend-task-definition-arn.txt
                    )

                    aws ecs update-service \
                      --cluster "$ECS_CLUSTER" \
                      --service "$FRONTEND_SERVICE" \
                      --task-definition "$FRONTEND_TASK_DEFINITION" \
                      > frontend-deployment.json

                    aws ecs update-service \
                      --cluster "$ECS_CLUSTER" \
                      --service "$BACKEND_SERVICE" \
                      --task-definition "$BACKEND_TASK_DEFINITION" \
                      > backend-deployment.json

                    echo "ECS deployments started."
                '''
            }
        }


        stage('Wait for Stable Services') {
            steps {
                /*
                 * Do not mark the pipeline successful merely because AWS
                 * accepted UpdateService.
                 *
                 * Wait until ECS reports both services stable.
                 */
                sh '''
                    set -eu

                    aws ecs wait services-stable \
                      --cluster "$ECS_CLUSTER" \
                      --services \
                        "$FRONTEND_SERVICE" \
                        "$BACKEND_SERVICE"

                    aws ecs describe-services \
                      --cluster "$ECS_CLUSTER" \
                      --services \
                        "$FRONTEND_SERVICE" \
                        "$BACKEND_SERVICE" \
                      --query 'services[].{
                        Service:serviceName,
                        Desired:desiredCount,
                        Running:runningCount,
                        Pending:pendingCount,
                        TaskDefinition:taskDefinition
                      }' \
                      --output table
                '''
            }
        }


        stage('Validate Live Application') {
            steps {
                /*
                 * Resolve the environment-specific ALB hostname at runtime.
                 * Nothing generated by AWS is hardcoded in the repository.
                 */
                sh '''
                    set -eu

                    ALB_DNS=$(
                      aws elbv2 describe-load-balancers \
                        --names "$ALB_NAME" \
                        --query 'LoadBalancers[0].DNSName' \
                        --output text
                    )

                    echo "Validating http://$ALB_DNS"

                    FRONTEND_STATUS=$(
                      curl \
                        --silent \
                        --show-error \
                        --output /dev/null \
                        --write-out '%{http_code}' \
                        "http://$ALB_DNS/"
                    )

                    test "$FRONTEND_STATUS" = "200"

                    API_RESPONSE=$(
                      curl \
                        --fail \
                        --silent \
                        --show-error \
                        "http://$ALB_DNS/api"
                    )

                    echo "$API_RESPONSE"

                    echo "$API_RESPONSE" \
                    | jq -e '
                        .id
                        | type == "string"
                        and length > 0
                      '

                    echo "Frontend returned HTTP 200."
                    echo "Backend returned a GUID."
                    echo "Deployment validation passed."
                '''
            }
        }
    }


    post {
        success {
            echo "Deployment completed successfully: ${env.IMAGE_TAG}"
        }

        failure {
            echo "Deployment failed. Review the failed stage before retrying."
        }

        always {
            /*
             * Keep the persistent Jenkins build host from accumulating
             * dangling Docker layers indefinitely.
             */
            sh '''
                docker image prune --force || true
            '''

            deleteDir()
        }
    }
}