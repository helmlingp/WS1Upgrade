# WS1Upgrade
 Upgrade WS1 UEM components using Blue/Green methodology

This powershell script automates stages of a WS1 UEM upgrade using a menu selection for each phase.
    It requires a JSON file with configuration of the environment.
    Requirements include:
     * VMware PowerCLI Module (will be imported automatically)
     * env.json file
     * Subfolders
        \Installer
            \Application - contains the extracted Application Server installer files
            \Cert - contains the certificate used for application servers
            \Configs - contains WS1 UEM installer config.xml files with role based names (CN_ConfigScript.xml, API_ConfigScript.xml, AWCM_ConfigScript.xml, DS_ConfigScript.xml)
            \DB - contains the extracted DB Server installer files
            \Prereqs - contains Java runtime (jre*.exe) and dotNET Framework runtime (ndp*.exe) versions that are specified by WS1 UEM version you are upgrading to
        \Tools - containing 7z1900-x64.exe
