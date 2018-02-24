pipeline { 
    agent any 
    stages {
        stage('Build') { 
            steps { 
                sh 'stack --nix build'
            }
        }
    }
}

