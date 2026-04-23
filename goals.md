I have an existing DNA methylation analysis pipeline that I would like to productize into a user-friendly MVP. The app will allow users to upload raw Illumina methylation array data (IDAT files, paired Red/Green channels, with optional sample metadata).

Upon upload, the system will execute a standardized analysis pipeline that includes preprocessing (e.g., normalization and QC), followed by downstream analyses such as dimensionality reduction (PCA/UMAP), unsupervised clustering, and copy number variation (CNV) inference.

The app will generate an automated, interactive HTML report summarizing results, including:

Quality control metrics (e.g., detection p-values, signal intensity, sample outliers) Visualization of sample relationships (PCA/UMAP plots). Clustering results with annotations Genome-wide CNV plots and segmentation. The goal is to provide a streamlined, reproducible, and accessible interface for researchers and clinicians to analyze methylation data without requiring command-line expertise.

The app will be used internally by researchers. A user can install the app on the local desktop to run. 

The input will be a .csv file contains the Sample identifier column named Sentrix_ID and the Basename column which has the absolute path. An example input file is samplesheet_epic_10.csv.

This app will utilize the already develop tool located /Volumes/qtran/MeQTrack.

This app is similar to this: https://mepylome.readthedocs.io/en/latest/ 