pipeline { 
    agent any 
    stages {
        stage('Build') { 
            steps { 
                echo 'env.PATH=' + env.PATH
                sh 'stack build'
            }
        }
    }
}

