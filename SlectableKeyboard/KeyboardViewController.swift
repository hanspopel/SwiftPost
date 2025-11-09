//
//  KeyboardViewController.swift
//  SlectableKeyboard
//
//  Created by Pascal Kaap on 09.11.25.
//

import UIKit
import PhotosUI

class KeyboardViewController: UIInputViewController, PHPickerViewControllerDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    
    @IBOutlet var nextKeyboardButton: UIButton!
    
    var photoSelectorButton: UIButton!
    var listSelectorButton: UIButton!
    
    // Sample list for list selector
    let items = ["Option 1", "Option 2", "Option 3"]
    
    // CollectionView for image thumbnails
    var collectionView: UICollectionView!
    var selectedImages: [UIImage] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupNextKeyboardButton()
        setupFeatureButtons()
        setupImageCollectionView()
    }
    
    // MARK: - Setup Buttons
    func setupNextKeyboardButton() {
        nextKeyboardButton = UIButton(type: .system)
        nextKeyboardButton.setTitle("Next Keyboard", for: .normal)
        nextKeyboardButton.sizeToFit()
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(nextKeyboardButton)
        
        NSLayoutConstraint.activate([
            nextKeyboardButton.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 10),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
    }
    
    func setupFeatureButtons() {
        // Photo Picker Button
        photoSelectorButton = UIButton(type: .system)
        photoSelectorButton.setTitle("Pick Photo", for: .normal)
        photoSelectorButton.translatesAutoresizingMaskIntoConstraints = false
        photoSelectorButton.addTarget(self, action: #selector(openPhotoPicker), for: .touchUpInside)
        view.addSubview(photoSelectorButton)
        
        // List Selector Button
        listSelectorButton = UIButton(type: .system)
        listSelectorButton.setTitle("Select Item", for: .normal)
        listSelectorButton.translatesAutoresizingMaskIntoConstraints = false
        listSelectorButton.addTarget(self, action: #selector(showListSelector), for: .touchUpInside)
        view.addSubview(listSelectorButton)
        
        // Layout buttons horizontally
        NSLayoutConstraint.activate([
            photoSelectorButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            photoSelectorButton.bottomAnchor.constraint(equalTo: nextKeyboardButton.topAnchor, constant: -10),
            
            listSelectorButton.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -10),
            listSelectorButton.bottomAnchor.constraint(equalTo: nextKeyboardButton.topAnchor, constant: -10)
        ])
    }
    
    // MARK: - CollectionView for Thumbnails
    func setupImageCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 5
        layout.itemSize = CGSize(width: 50, height: 50)
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ImageCell.self, forCellWithReuseIdentifier: "ImageCell")
        
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            collectionView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 10),
            collectionView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -10),
            collectionView.bottomAnchor.constraint(equalTo: photoSelectorButton.topAnchor, constant: -10),
            collectionView.heightAnchor.constraint(equalToConstant: 60)
        ])
    }
    
    // MARK: - PHPicker
    @objc func openPhotoPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 5
        config.filter = .images
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        self.present(picker, animated: true)
    }
    
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        
        for result in results {
            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                    if let image = obj as? UIImage {
                        DispatchQueue.main.async {
                            self?.selectedImages.append(image)
                            self?.collectionView.reloadData()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - UICollectionView DataSource & Delegate
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return selectedImages.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ImageCell", for: indexPath) as! ImageCell
        cell.imageView.image = selectedImages[indexPath.item]
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Insert placeholder text representing the image
        textDocumentProxy.insertText("[img\(indexPath.item + 1)]")
    }
    
    // MARK: - List Selector
    @objc func showListSelector() {
        let alert = UIAlertController(title: "Select an Item", message: nil, preferredStyle: .alert)
        for item in items {
            alert.addAction(UIAlertAction(title: item, style: .default, handler: { [weak self] _ in
                self?.textDocumentProxy.insertText(item)
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.present(alert, animated: true)
    }
    
    // MARK: - Text Color Handling
    override func textDidChange(_ textInput: UITextInput?) {
        let proxy = textDocumentProxy
        let color: UIColor = proxy.keyboardAppearance == .dark ? .white : .black
        nextKeyboardButton.setTitleColor(color, for: [])
        photoSelectorButton.setTitleColor(color, for: [])
        listSelectorButton.setTitleColor(color, for: [])
    }
}

// MARK: - Custom UICollectionViewCell
class ImageCell: UICollectionViewCell {
    var imageView: UIImageView!
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView = UIImageView(frame: contentView.bounds)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 5
        contentView.addSubview(imageView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
